#!/usr/bin/env python3
"""Compare two frozen production consumers with alternating fresh-process pairs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import time

import analyze
import measure


def checked_build(output):
    metadata = json.loads((output / 'BUILD.json').read_text())
    digest = hashlib.sha256((output / 'native/bench').read_bytes()).hexdigest()
    if digest != metadata['executable_sha256']:
        raise SystemExit('Measured executable differs from its recorded build')
    for name, expected in metadata['source_sha256'].items():
        if hashlib.sha256((output / 'source' / name).read_bytes()).hexdigest() != expected:
            raise SystemExit('Benchmark source differs from its recorded build: ' + name)
    for name in measure.WORKLOADS:
        if (output / 'fixtures' / (name + '.bin')).read_bytes() != measure.fixture(name):
            raise SystemExit('Wire fixture differs from its independent definition: ' + name)
    return metadata


def distribution(rows, metric):
    values = [row[metric] * 1e6 / row['count'] for row in rows]
    return dict(median=statistics.median(values), min=min(values), max=max(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cpu', type=int, required=True)
    parser.add_argument('--quiet-note', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--batch-seconds', type=float, default=0.5)
    parser.add_argument('--sample-seconds', type=float, default=3.0)
    options = parser.parse_args()
    before, after, output = (path.resolve() for path in
                             (options.before, options.after, options.output))
    builds = {'before': checked_build(before), 'after': checked_build(after)}
    if builds['before']['source_sha256'] != builds['after']['source_sha256']:
        raise SystemExit('Comparison requires exactly matching benchmark consumer sources')
    if options.cpu not in os.sched_getaffinity(0):
        raise SystemExit('CPU is outside the allowed affinity set')
    output.mkdir(exist_ok=False)
    reference = json.loads((before / 'summary.json').read_text())
    result = dict(started=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  cpu=options.cpu, quiet_note=options.quiet_note.read_text(),
                  load_start=os.getloadavg(), repeats=options.repeats,
                  batch_seconds=options.batch_seconds, sample_seconds=options.sample_seconds,
                  executable_sha256={key: value['executable_sha256'] for key, value in builds.items()},
                  source_sha256=builds['before']['source_sha256'], rows=[], profiles=[])
    paths = {'before': before, 'after': after}
    for case_index, case in enumerate(reference):
        name, operation = case['workload'], case['operation']
        count = max(1, round(options.batch_seconds * 1e6 / case['warm_cpu_us']['median']))
        rows = {'before': [], 'after': []}
        pairs = []
        for repeat in range(options.repeats):
            order = ['before', 'after']
            if (case_index + repeat) % 2:
                order.reverse()
            pair = {}
            for label in order:
                row = measure.run_one(paths[label], builds[label], options.cpu,
                                      name, operation, count, 64)
                rows[label].append(row)
                pair[label] = row
            pairs.append(dict(order=order, **pair))
        summary = dict(workload=name, operation=operation, wire_bytes=case['wire_bytes'],
                       count=count, pairs=pairs)
        for label in ('before', 'after'):
            summary[label + '_cpu_us'] = distribution(rows[label], 'cpu_seconds')
            summary[label + '_wall_us'] = distribution(rows[label], 'wall_seconds')
        summary['after_before_cpu_ratio'] = (summary['after_cpu_us']['median'] /
                                             summary['before_cpu_us']['median'])
        summary['paired_after_before_cpu_ratios'] = [
            pair['after']['cpu_seconds'] / pair['before']['cpu_seconds'] for pair in pairs]
        result['rows'].append(summary)
        (output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
        print(f"{name} {operation}: {summary['before_cpu_us']['median']:.3f} -> "
              f"{summary['after_cpu_us']['median']:.3f} us", flush=True)
    # Reprofile the principal width/allocation cases on the optimized consumer.
    for case_index, name in enumerate(('flat4', 'flat16', 'flat64', 'records128')):
        case = next(row for row in result['rows']
                    if row['workload'] == name and row['operation'] == 'deserialize')
        count = max(1, round(options.sample_seconds * 1e6 / case['after_cpu_us']['median']))
        sample_path = output / f'{name}-deserialize.samples.tsv'
        pair = [('control', None), ('sampled', sample_path)]
        if case_index % 2:
            pair.reverse()
        rows = {label: measure.run_one(after, builds['after'], options.cpu,
                                       name, 'deserialize', count, 64, path)
                for label, path in pair}
        resolved = analyze.profile(sample_path)
        (output / f'{name}-deserialize.resolved.json').write_text(json.dumps(resolved, indent=2) + '\n')
        result['profiles'].append(dict(workload=name, operation='deserialize', count=count,
                                        sample_count=resolved['samples'],
                                        samples_dropped=rows['sampled']['dropped'],
                                        sampled_control_cpu_ratio=(rows['sampled']['cpu_seconds'] /
                                                                   rows['control']['cpu_seconds']),
                                        category_samples=resolved['categories'],
                                        top_functions=resolved['top_functions']))
        print(f"{name} deserialize profile: {resolved['samples']} samples", flush=True)
    result['load_end'] = os.getloadavg()
    result['finished'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    (output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
