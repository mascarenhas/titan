#!/usr/bin/env python3
"""Resolve production SIGPROF samples and summarize cold/warm protobuf timings."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import statistics
import struct
import subprocess


def resolve(image, addresses):
    executable = Path(image)
    if not executable.is_file():
        return {}
    result = subprocess.run(['addr2line', '-a', '-f', '-i', '-C', '-e', str(executable)],
                            input=''.join(f'{address:x}\n' for address in addresses),
                            text=True, capture_output=True, check=True)
    resolved = {}
    current = None
    pending = []
    for line in result.stdout.splitlines():
        if re.fullmatch(r'0x[0-9a-fA-F]+', line):
            if current is not None:
                resolved[current] = list(zip(pending[::2], pending[1::2]))
            current = int(line, 16); pending = []
        else:
            pending.append(line)
    if current is not None:
        resolved[current] = list(zip(pending[::2], pending[1::2]))
    return resolved


def category(frames, symbol):
    function, location = frames[0] if frames else (symbol, '??:0')
    if function == '??': function = symbol
    lower = function.lower()
    if re.search(r'_ℱ_(projection|construction)(?:[.]|$)', function):
        return 'generated_projection_construction'
    if 'titan_reflect' in lower or 'reflect.titan:' in location:
        return 'reflection_api_and_lookup'
    if 'resolve_type' in lower and 'protobuf' in lower:
        return 'descriptor_resolution'
    if 'protobuf' in lower:
        if 'wirereader' in lower:
            return 'wire_parse_write'
        if 'message' in lower and ('last' in lower or 'merged' in lower):
            return 'wire_field_lookup'
        if any(name in lower for name in ('read_message', 'read_varint', 'write_varint', 'write_key', 'write_bytes', 'zigzag', 'unzigzag')):
            return 'wire_parse_write'
        return 'codec_dispatch_and_traversal'
    if ('lgc.c:' in location or 'lmem.c:' in location or
        any(name in lower for name in ('malloc', 'realloc', 'calloc', 'free', 'luac_', 'luam_', 'lual_alloc', 'unlink_chunk', 'tcache_'))):
        return 'allocator_and_gc_shared'
    if ('titan_string' in lower or '/string/' in location or
        any(name in lower for name in ('memcpy', 'memmove', 'memset', 'memcmp'))):
        return 'strings_buffers_and_copy'
    if function == '?' or function == '??':
        return 'unresolved'
    return 'other_runtime_and_harness'


def profile(path):
    observations = collections.Counter()
    symbols = {}
    relocatable = {}
    for line in path.read_text().splitlines():
        if line.startswith('#'): continue
        raw, base, image, symbol = line.split('\t')
        address = int(raw, 16)
        if image not in relocatable:
            relocatable[image] = False
            if Path(image).is_file():
                with Path(image).open('rb') as binary: header = binary.read(20)
                if header[:4] == b'\x7fELF':
                    order = '<' if header[5] == 1 else '>'
                    relocatable[image] = struct.unpack_from(order + 'H', header, 16)[0] == 3
        if relocatable[image]:
            address -= int(base, 16)
        observations[(image, address)] += 1
        symbols[(image, address)] = symbol
    by_image = collections.defaultdict(list)
    for image, address in observations:
        by_image[image].append(address)
    locations = {image: resolve(image, addresses) for image, addresses in by_image.items()}
    buckets = collections.Counter()
    functions = collections.Counter()
    details = []
    for (image, address), count in observations.items():
        frames = locations[image].get(address, [])
        symbol = symbols[(image, address)]
        bucket = category(frames, symbol)
        buckets[bucket] += count
        functions[(frames[0][0] if frames else symbol)] += count
        details.append(dict(image=image, address=hex(address), count=count, category=bucket, frames=frames, symbol=symbol))
    return dict(samples=sum(observations.values()), categories=dict(buckets),
                top_functions=functions.most_common(20), resolved_locations=details)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    options = parser.parse_args()
    output = options.output.resolve()
    build = json.loads((output / 'BUILD.json').read_text())
    if hashlib.sha256((output / 'native/bench').read_bytes()).hexdigest() != build['executable_sha256']:
        raise SystemExit('Measured executable differs from the recorded build')
    rows = [json.loads(line) for line in (output / 'measurements.jsonl').read_text().splitlines()]
    grouped = collections.defaultdict(list)
    for row in rows:
        grouped[(row['workload'], row['operation'])].append(row)
    summary = []
    for (workload, operation), cases in grouped.items():
        warm = [row for row in cases if row['phase'] == 'warm']
        cold = [row for row in cases if row['phase'] == 'first_call']
        sample = next(row for row in cases if row['phase'] == 'sampled')
        control = next(row for row in cases if row['phase'] == 'sampling_control')
        cpu = [row['cpu_seconds'] * 1e6 / row['count'] for row in warm]
        wall = [row['wall_seconds'] * 1e6 / row['count'] for row in warm]
        attribution = profile(output / f'{workload}-{operation}.samples.tsv')
        (output / f'{workload}-{operation}.resolved.json').write_text(json.dumps(attribution, indent=2) + '\n')
        summary.append(dict(workload=workload, operation=operation, wire_bytes=warm[0]['wire_bytes'],
                            batch_count=warm[0]['count'], warm_cpu_us=dict(median=statistics.median(cpu), min=min(cpu), max=max(cpu)),
                            warm_wall_us=dict(median=statistics.median(wall), min=min(wall), max=max(wall)),
                            first_call_cpu_us=[row['cpu_seconds'] * 1e6 for row in cold],
                            sampled_cpu_ratio=sample['cpu_seconds'] / control['cpu_seconds'],
                            sample_count=attribution['samples'], samples_dropped=sample['dropped'],
                            category_samples=attribution['categories'], top_functions=attribution['top_functions']))
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    for row in summary:
        reflection = sum(row['category_samples'].get(name, 0) for name in
                         ('reflection_api_and_lookup', 'generated_projection_construction', 'descriptor_resolution'))
        print(f"{row['workload']:12s} {row['operation']:11s} {row['warm_cpu_us']['median']:10.3f} us "
              f"reflection {reflection / row['sample_count']:.1%} ({row['sample_count']} samples) "
              f"sampling/control {row['sampled_cpu_ratio']:.3f}")


if __name__ == '__main__':
    main()
