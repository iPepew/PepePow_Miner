#!/usr/bin/env python3
"""Create a deterministic preparation bundle; never an installable stable release.

Each input is a build directory with PROFILE_BUILD.json and six exact binaries.
No file is executed. Runtime configs, logs and arbitrary directory contents are
excluded by an explicit allowlist. Optional adapters remain preparation-only.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

TARGETS = ('pepepowminer', 'pepepow_core_tests', 'pepepow_cuda_tests',
           'pepepow_cuda_header80_validation', 'pepepow_header80_benchmark',
           'pepepow_header80_differential')
ROOT = 'pepew-miner'
RUNTIME_FILES = {
    'pepepowminer': ('hiveos/pepepowminer', 0o755),
    'h-run.sh': ('hiveos/h-run.sh', 0o755),
    'h-config.sh': ('hiveos/h-config.sh', 0o755),
    'h-stats.sh': ('hiveos/h-stats.sh', 0o755),
    'h-manifest.conf': ('hiveos/h-manifest.conf', 0o644),
    'libexec/stratum-replay-proxy.py': ('hiveos/stratum-replay-proxy.py', 0o755),
    'libexec/console-monitor.sh': ('hiveos/console-monitor.sh', 0o755),
    'README.md': ('docs/PUBLIC_README.md', 0o644),
    'CHANGELOG.md': ('docs/PUBLIC_CHANGELOG.md', 0o644),
    'LICENSE': ('LICENSE', 0o644),
    'licenses/BLAKE3-CC0.txt': ('licenses/BLAKE3-CC0.txt', 0o644),
    'licenses/nlohmann-json-MIT.txt': ('licenses/nlohmann-json-MIT.txt', 0o644),
    'licenses/NOTICE.md': ('licenses/NOTICE.md', 0o644),
    'licenses/NVIDIA-CUDA.md': ('licenses/NVIDIA-CUDA.md', 0o644),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def read_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'required regular file missing or symlink: {path.name}')
    return path.read_bytes()


def assemble(general, v100, version, expected_general, expected_v100,
             runtime=None, runtime_commit=None):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-preparation\.[0-9]+', version):
        raise ValueError('version must explicitly be X.Y.Z-preparation.N')
    files = {}
    profiles = {}
    for name, directory, expected in [('general', general, expected_general),
                                      ('v100', v100, expected_v100)]:
        if not re.fullmatch(r'[0-9a-f]{40}', expected):
            raise ValueError('expected source must be a full commit SHA')
        directory = Path(directory)
        if directory.is_symlink():
            raise ValueError('profile directory must not be a symlink')
        source = json.loads(read_regular(directory / 'PROFILE_BUILD.json'))
        if source.get('source_commit') != expected:
            raise ValueError(f'{name}: source identity mismatch')
        if source.get('status') != 'compiled-cpu-tested-gpu-unverified':
            raise ValueError(f'{name}: requires completed CPU preparation build')
        hashes = source.get('binary_sha256', {})
        if set(hashes) != set(TARGETS):
            raise ValueError(f'{name}: incomplete or unexpected binary inventory')
        for target in TARGETS:
            data = read_regular(directory / target)
            if not data or digest(data) != hashes[target]:
                raise ValueError(f'{name}/{target}: binary hash mismatch or empty file')
            prefix = f'bin/{name}' if target == 'pepepowminer' else f'tests/offline/{name}'
            files[f'{prefix}/{target}'] = (data, 0o755)
        # Deliberately rebuild metadata from approved fields. Input logs or
        # arbitrary metadata may contain credentials and are never copied.
        profiles[name] = {'source_commit': expected, 'binary_sha256': hashes,
                          'cpu_build_status_reported': source['status'],
                          'gpu_validation': 'not-established-by-packager',
                          'pool_validation': 'not-established-by-packager'}
    files['VERSION'] = ((version + '\n').encode(), 0o644)
    files['README.md'] = (b'# PepeW Miner preparation profile bundle\n\n'
        b'Not installable in HiveOS and not a stable release. No launch adapter is included.\n'
        b'Contains separate general and V100 builds plus matching offline test binaries.\n'
        b'Packaging checks hashes, not GPU correctness or speed. Do not deploy as public 1.0.\n', 0o644)
    runtime_metadata = None
    if runtime is not None:
        if not runtime_commit or not re.fullmatch(r'[0-9a-f]{40}', runtime_commit):
            raise ValueError('runtime requires its full source commit SHA')
        runtime = Path(runtime)
        for destination, (source, mode) in RUNTIME_FILES.items():
            relative = Path(source)
            if runtime.is_symlink() or any((runtime / parent).is_symlink()
                                           for parent in relative.parents):
                raise ValueError('runtime path must not traverse a symlink')
            files[destination] = (read_regular(runtime / source), mode)
        runtime_metadata = {'source_commit': runtime_commit,
                            'hiveos_adapters': True,
                            'hardware_validation': 'pending',
                            'start_requires': 'PEPEW_ALLOW_UNVERIFIED=1',
                            'binary_profiles': {'general': 'architecture-default',
                                                'v100': 'sm70-V100-fixed-128-threads'}}
    elif runtime_commit is not None:
        raise ValueError('runtime commit provided without runtime source directory')
    files['BUILD_MANIFEST.json'] = (encode({'schema_version': 1,
        'product': 'PepeW Miner', 'version': version,
        'package_kind': 'preparation-profile-bundle', 'installable': False,
        'profiles': profiles, 'runtime': runtime_metadata,
        'files': {p: {'sha256': digest(d), 'mode': oct(m)}
                  for p, (d, m) in sorted(files.items())}}), 0o644)
    sums = ''.join(f'{digest(data)}  {path}\n' for path, (data, _) in sorted(files.items()))
    files['SHA256SUMS'] = (sums.encode(), 0o644)
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for path, (data, mode) in sorted(files.items()):
                entry = tarfile.TarInfo(f'{ROOT}/{path}')
                entry.size, entry.mode, entry.mtime = len(data), mode, 0
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = ''
                archive.addfile(entry, io.BytesIO(data))
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('general', 'v100', 'version', 'expected-general', 'expected-v100', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--runtime', help='source checkout supplying allowlisted adapters/docs')
    parser.add_argument('--runtime-commit', help='full commit of the runtime checkout')
    args = parser.parse_args()
    data = assemble(args.general, args.v100, args.version,
                    args.expected_general, args.expected_v100, args.runtime, args.runtime_commit)
    # Exclusive create prevents overwriting a previous artifact or following a
    # symlink. A failed write removes only the new file created by this call.
    destination = Path(args.output)
    with destination.open('xb') as stream:
        try:
            stream.write(data)
        except BaseException:
            destination.unlink()
            raise
    print(f'{digest(data)}  {destination.name}')


if __name__ == '__main__':
    main()
