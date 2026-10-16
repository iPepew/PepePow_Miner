#!/usr/bin/env python3
"""Inspect a hash-pinned profile archive without executing its binaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


def readelf(path, flag):
    return subprocess.run(['readelf', flag, str(path)], check=True,
                          capture_output=True, text=True, timeout=20).stdout


def audit(archive, expected_sha256):
    data = Path(archive).read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if not re.fullmatch('[0-9a-f]{64}', expected_sha256) or actual != expected_sha256:
        raise ValueError('archive SHA256 mismatch')
    results = {}
    with tarfile.open(archive, 'r:gz') as tar, tempfile.TemporaryDirectory() as tmp:
        manifest = json.load(tar.extractfile('pepew-miner/BUILD_MANIFEST.json'))
        names = tar.getnames()
        if len(names) != len(set(names)):
            raise ValueError('duplicate archive paths')
        for profile, metadata in sorted(manifest['profiles'].items()):
            if profile not in ('general', 'v100'):
                raise ValueError('unknown profile')
            for target, expected in sorted(metadata['binary_sha256'].items()):
                if not re.fullmatch('[A-Za-z0-9_]+', target):
                    raise ValueError('invalid executable name')
                prefix = 'bin' if target == 'pepepowminer' else 'tests/offline'
                name = f'pepew-miner/{prefix}/{profile}/{target}'
                member = tar.getmember(name)
                if not member.isfile() or member.size > 100 * 1024 * 1024:
                    raise ValueError('invalid executable member')
                binary = tar.extractfile(member).read()
                if hashlib.sha256(binary).hexdigest() != expected:
                    raise ValueError('binary SHA256 mismatch')
                local = Path(tmp) / f'{profile}-{target}'
                local.write_bytes(binary)  # deliberately not marked executable
                header = readelf(local, '-hW')
                if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
                    raise ValueError('expected Linux x86_64 ELF')
                versions = readelf(local, '-VW')
                needed_versions = sorted(set(re.findall(
                    r'Name: ((?:GLIBC|GLIBCXX|CXXABI)_[0-9.]+)', versions)))
                maximum = {}
                for family in ('GLIBC', 'GLIBCXX', 'CXXABI'):
                    values = [v for v in needed_versions if v.startswith(family + '_')]
                    if values:
                        maximum[family] = max(values, key=lambda v: tuple(map(int, v.split('_')[1].split('.'))))
                dynamic = readelf(local, '-dW')
                symbols = readelf(local, '-sW')
                defined_cuda = []
                for line in symbols.splitlines():
                    fields = line.split()
                    if len(fields) >= 8 and fields[6] != 'UND' and fields[7] in (
                            'cudaGetDeviceCount', 'cudaMalloc', 'cudaFree',
                            'cudaRuntimeGetVersion', '__cudaRegisterFatBinary'):
                        defined_cuda.append(fields[7])
                results[f'{profile}/{target}'] = {
                    'sha256': expected, 'elf_class': 'ELF64', 'machine': 'x86_64',
                    'needed_libraries': re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic),
                    'symbol_version_requirements': needed_versions,
                    'maximum_symbol_versions': maximum,
                    'rpath_or_runpath': re.findall(r'\((?:RPATH|RUNPATH)\).*?\[(.*?)\]', dynamic),
                    'defined_cuda_runtime_symbols': sorted(set(defined_cuda)),
                }
    return {'schema_version': 1, 'archive_sha256': actual,
            'source_commits': {p: v['source_commit'] for p, v in manifest['profiles'].items()},
            'executables': results, 'binaries_executed': False,
            'limits': ['ELF requirements are not a target-host compatibility test',
                       'Defined CUDA symbols show embedded runtime code, not its exact version or redistribution terms',
                       'GPU correctness and pool acceptance are not tested']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = audit(args.archive, args.sha256)
    with Path(args.output).open('x') as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(f'ELF_AUDIT_PASS: {len(report["executables"])} binaries inspected; none executed')


if __name__ == '__main__':
    main()
