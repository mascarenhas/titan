#!/usr/bin/env python3
"""Build and measure an isolated production protobuf consumer (Linux x86_64)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
WORKLOADS = ('flat4', 'flat16', 'flat64', 'bytes16', 'bytes4096', 'nested',
             'union', 'ints8', 'ints256', 'records8', 'records128')


def varint(number):
    result = bytearray()
    while number >= 128:
        result.append((number & 127) | 128)
        number >>= 7
    return bytes(result + bytes([number]))


def integer(field, number):
    zigzag = number * 2 if number >= 0 else -number * 2 - 1
    return varint(field << 3) + varint(zigzag)


def message(field, payload):
    return varint((field << 3) | 2) + varint(len(payload)) + payload


def flat(values):
    return b''.join(integer(index, value) for index, value in enumerate(values, 1))


def fixture(name):
    base = flat((-13, -6, 1, 8))
    if name.startswith('flat'):
        return flat(i * 7 - 20 for i in range(1, int(name[4:]) + 1))
    if name.startswith('bytes'):
        return integer(1, 42) + message(2, b'x' * int(name[5:]))
    if name == 'nested':
        return message(1, base) + message(2, flat((10, 20, 30, 40))) + message(3, b'nested')
    if name == 'union':
        return message(2, integer(1, 42) + message(2, base))
    if name.startswith('ints'):
        slots = b''.join(message(1, integer(1, i * 7 - 20)) for i in range(1, int(name[4:]) + 1))
    else:
        slots = b''.join(message(1, message(1, flat((i, -i, i + 1, i + 2))))
                         for i in range(1, int(name[7:]) + 1))
    return message(1, slots + integer(2, 0))


def environment(prefix):
    env = {key: os.environ[key] for key in ('HOME', 'USER', 'TMPDIR') if key in os.environ}
    env.update(PATH=f'{prefix}/bin:/usr/bin:/bin',
               LANG='C', LC_ALL='C', TZ='UTC', CC='/usr/bin/gcc', AR='/usr/bin/ar',
               RANLIB='/usr/bin/ranlib', CCACHE_DISABLE='1', TITAN_BUILD_PROFILE='production',
               TITAN_PROBE_CACHE_DISABLE='1', TITAN_JOBS='1')
    return env


def command(argv, cwd, env, log):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True)
    Path(log).write_text('$ ' + ' '.join(map(str, argv)) + '\n' + result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout


def build(options):
    prefix = options.prefix.resolve()
    if (prefix / 'etc/titan/build-profile').read_text().strip() != 'production':
        raise SystemExit('A separately built production SDK is required')
    output = options.output.resolve()
    output.mkdir(exist_ok=False)
    source = output / 'source'
    source.mkdir()
    for name in ('bench.titan', 'probe.h', 'probe.c'):
        shutil.copy2(HERE / name, source / name)
    (output / 'fixtures').mkdir()
    for name in WORKLOADS:
        (output / 'fixtures' / (name + '.bin')).write_bytes(fixture(name))
    env = environment(prefix)
    command(['/usr/bin/gcc', '-O3', '-g1', '-c', 'probe.c', '-o', str(output / 'probe.o')],
            source, env, output / 'probe-build.log')
    command([str(prefix / 'bin/titanc'), '--verbose', '--static', '--no-uv-bootstrap', '--output',
             str(output / 'native'), 'bench', '-X', str(output / 'probe.o')],
            source, env, output / 'consumer-build.log')
    metadata = dict(prefix=str(prefix), output=str(output), environment=env,
                    platform=platform.platform(), compiler=subprocess.check_output(['/usr/bin/gcc', '--version'], text=True),
                    source_sha256={name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                                   for name in ('bench.titan', 'probe.c', 'probe.h')},
                    executable_sha256=hashlib.sha256((output / 'native/bench').read_bytes()).hexdigest(),
                    provider_sha256={name: hashlib.sha256((prefix / name).read_bytes()).hexdigest()
                                     for name in ('bin/lua', 'lib/liblua.a', 'lib/titan/0.6/libtitan.a',
                                                  'lib/titan/0.6/titan.a')})
    if options.source_manifest:
        shutil.copy2(options.source_manifest, output / 'provider-source-manifest.json')
        metadata['provider_source_manifest_sha256'] = hashlib.sha256(options.source_manifest.read_bytes()).hexdigest()
    (output / 'BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(dict(built=str(output), fixture_sizes={name: len(fixture(name)) for name in WORKLOADS})))


def run_one(output, metadata, cpu, name, operation, count, warmup, sample_path=None):
    argv = [str(output / 'native/bench'), name, operation, str(count), str(warmup),
            str(output / 'fixtures' / (name + '.bin')), str(sample_path) if sample_path else '-']
    result = subprocess.run(argv, cwd=output, env=metadata['environment'], text=True,
                            capture_output=True, timeout=120,
                            preexec_fn=lambda: os.sched_setaffinity(0, {cpu}))
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    row = json.loads(result.stdout)
    if row['checksum'] != count * row['wire_bytes']:
        raise RuntimeError('benchmark checksum mismatch')
    return row


def measure(options):
    output = options.output.resolve()
    metadata = json.loads((output / 'BUILD.json').read_text())
    if options.cpu not in os.sched_getaffinity(0):
        raise SystemExit('CPU is outside the allowed affinity set')
    path = output / 'measurements.jsonl'
    if path.exists():
        raise SystemExit('Refusing to overwrite existing measurements')
    notes = dict(started=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), cpu=options.cpu,
                 affinity=sorted(os.sched_getaffinity(0)), load_start=os.getloadavg(),
                 lscpu=subprocess.check_output(['lscpu'], text=True),
                 processes_start=subprocess.check_output(['ps', '-eo', 'pid,comm,pcpu', '--sort=-pcpu'], text=True),
                 quiet_note=options.quiet_note.read_text(), repeats=options.repeats,
                 batch_seconds=options.batch_seconds, sample_seconds=options.sample_seconds)
    (output / 'RUN.json').write_text(json.dumps(notes, indent=2) + '\n')
    with path.open('w') as sink:
        def save(row, phase):
            row['phase'] = phase
            sink.write(json.dumps(row) + '\n'); sink.flush()
        for workload_index, name in enumerate(WORKLOADS):
            for operation_index, operation in enumerate(('serialize', 'deserialize')):
                for repeat in range(options.repeats):
                    row = run_one(output, metadata, options.cpu, name, operation, 1, 0)
                    row['repeat'] = repeat; save(row, 'first_call')
                count = 128
                while True:
                    pilot = run_one(output, metadata, options.cpu, name, operation, count, 32)
                    save(pilot, 'calibration')
                    if pilot['cpu_seconds'] >= 0.04: break
                    count *= 2
                count = max(1, round(count * options.batch_seconds / pilot['cpu_seconds']))
                warm_rows = []
                for repeat in range(options.repeats):
                    row = run_one(output, metadata, options.cpu, name, operation, count, 64)
                    row['repeat'] = repeat; save(row, 'warm'); warm_rows.append(row)
                sample_count = max(count, round(count * options.sample_seconds /
                                               statistics.median(row['cpu_seconds'] for row in warm_rows)))
                # Paired long batches distinguish sampling overhead from short-batch noise.
                sample_path = output / f'{name}-{operation}.samples.tsv'
                pair = [('sampling_control', None), ('sampled', sample_path)]
                if (workload_index + operation_index) % 2: pair.reverse()
                for phase, samples in pair:
                    save(run_one(output, metadata, options.cpu, name, operation, sample_count, 64, samples), phase)
                print(f'{name} {operation}: {count} ops/batch; {sample_count} sampled ops', flush=True)
    notes['load_end'] = os.getloadavg()
    notes['finished'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    (output / 'RUN.json').write_text(json.dumps(notes, indent=2) + '\n')


def recheck(options):
    """Repeat unsampled timings against the same executable after other work stops."""
    output = options.output.resolve()
    metadata = json.loads((output / 'BUILD.json').read_text())
    if hashlib.sha256((output / 'native/bench').read_bytes()).hexdigest() != metadata['executable_sha256']:
        raise SystemExit('Measured executable differs from the recorded build')
    if options.cpu not in os.sched_getaffinity(0):
        raise SystemExit('CPU is outside the allowed affinity set')
    rows = json.loads((output / 'summary.json').read_text())
    path = output / 'recheck.json'
    if path.exists():
        raise SystemExit('Refusing to overwrite existing recheck measurements')
    result = dict(started=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  cpu=options.cpu, quiet_note=options.quiet_note.read_text(),
                  load_start=os.getloadavg(), repeats=options.repeats,
                  batch_seconds=options.batch_seconds, rows=[])
    for row in rows:
        count = max(1, round(options.batch_seconds * 1e6 / row['warm_cpu_us']['median']))
        measured = [run_one(output, metadata, options.cpu, row['workload'],
                            row['operation'], count, 64) for _ in range(options.repeats)]
        cpu = [item['cpu_seconds'] * 1e6 / count for item in measured]
        wall = [item['wall_seconds'] * 1e6 / count for item in measured]
        result['rows'].append(dict(workload=row['workload'], operation=row['operation'],
                                   count=count, repetitions=measured,
                                   warm_cpu_us=dict(median=statistics.median(cpu), min=min(cpu), max=max(cpu)),
                                   warm_wall_us=dict(median=statistics.median(wall), min=min(wall), max=max(wall)),
                                   initial_median_ratio=statistics.median(cpu) / row['warm_cpu_us']['median']))
        path.write_text(json.dumps(result, indent=2) + '\n')
        print(f"{row['workload']} {row['operation']}: {statistics.median(cpu):.3f} us", flush=True)
    result['load_end'] = os.getloadavg()
    result['finished'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    path.write_text(json.dumps(result, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    builder = subparsers.add_parser('build')
    builder.add_argument('--prefix', type=Path, required=True)
    builder.add_argument('--output', type=Path, required=True)
    builder.add_argument('--source-manifest', type=Path)
    runner = subparsers.add_parser('run')
    runner.add_argument('--output', type=Path, required=True)
    runner.add_argument('--cpu', type=int, required=True)
    runner.add_argument('--quiet-note', type=Path, required=True)
    runner.add_argument('--repeats', type=int, default=5)
    runner.add_argument('--batch-seconds', type=float, default=0.25)
    runner.add_argument('--sample-seconds', type=float, default=5.0)
    checker = subparsers.add_parser('recheck')
    checker.add_argument('--output', type=Path, required=True)
    checker.add_argument('--cpu', type=int, required=True)
    checker.add_argument('--quiet-note', type=Path, required=True)
    checker.add_argument('--repeats', type=int, default=5)
    checker.add_argument('--batch-seconds', type=float, default=0.5)
    options = parser.parse_args()
    {'build': build, 'run': measure, 'recheck': recheck}[options.command](options)


if __name__ == '__main__':
    main()
