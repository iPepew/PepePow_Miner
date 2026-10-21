#!/usr/bin/env python3
"""Package only the pinned RTX-validated miner; never execute a GPU program."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

PACKAGE_ROOT = 'pepew-miner-1.0.0-linux-x86_64'

SOURCE = '2292825ea66a577a13e61ad63695b890396bf38b'
MINER = '96d59fe347272af0e6be4c5b7f4e90e92c4b96912c0b5a738a207266f1eaee2c'
RUNTIME = {
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

def sha(data):
    return hashlib.sha256(data).hexdigest()

def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('expected regular file: ' + str(path))
    return path.read_bytes()

def assemble(binary, runtime, runtime_commit):
    if not re.fullmatch('[0-9a-f]{40}', runtime_commit):
        raise ValueError('full runtime source commit required')
    data = regular(Path(binary))
    if sha(data) != MINER:
        raise ValueError('miner differs from validated RTX binary')
    root = Path(runtime)
    files = {'bin/general/pepepowminer': (data, 0o755),
             'VERSION': (b'1.0.0\n', 0o644)}
    for dest, (source, mode) in RUNTIME.items():
        path = root / source
        if any(p.is_symlink() for p in path.parents):
            raise ValueError('runtime path traverses symlink')
        files[dest] = (regular(path), mode)
    manifest = {
        'schema_version': 1, 'product': 'PepeW Miner', 'version': '1.0.0',
        'package_root': PACKAGE_ROOT, 'packaging_revision': 2,
        'installable': True, 'profiles': ['general'], 'v100_included': False,
        'binary_source': SOURCE, 'binary_sha256': MINER,
        'runtime_source': runtime_commit,
        'validation': {'gpu': 'RTX 3080', 'run': 39242460053,
                       'differential_cases': 100000, 'mismatches': 0,
                       'pool_seconds': 120, 'accepted': 22, 'rejected': 0,
                       'scope': 'same binary; prior runtime; final wrappers CPU-tested',
                       'final_archive_gpu_tested': False},
        'files': {p: {'sha256': sha(d), 'mode': oct(m)}
                  for p, (d, m) in sorted(files.items())}}
    files['BUILD_MANIFEST.json'] = ((json.dumps(manifest, indent=2, sort_keys=True)+'\n').encode(), 0o644)
    files['SHA256SUMS'] = (''.join(f'{sha(d)}  {p}\n' for p, (d, _) in sorted(files.items())).encode(), 0o644)
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for path, (data, mode) in sorted(files.items()):
                entry = tarfile.TarInfo(PACKAGE_ROOT + '/' + path)
                entry.size, entry.mode, entry.mtime = len(data), mode, 0
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = ''
                archive.addfile(entry, io.BytesIO(data))
    return output.getvalue()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'runtime', 'runtime-commit', 'output'):
        parser.add_argument('--'+name, required=True)
    args = parser.parse_args()
    data = assemble(args.binary, args.runtime, args.runtime_commit)
    destination = Path(args.output)
    with destination.open('xb') as stream:
        stream.write(data)
    with Path(str(destination)+'.sha256').open('x') as stream:
        stream.write(f'{sha(data)}  {destination.name}\n')
    print(f'{sha(data)}  {destination.name}')
