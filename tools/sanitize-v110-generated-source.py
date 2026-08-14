from pathlib import Path

path = Path('native/src/cuda/v1/header80_backend_part07.inc')
data = path.read_bytes()
count = data.count(b'\x00')
if count:
    # prepare-v110's embedded C++ template historically encoded '\0' through a
    # normal Python triple-quoted string, which writes a literal NUL byte. The
    # C++ test only needs an empty-string check; byte value zero is equivalent
    # and avoids compiler diagnostics entirely.
    data = data.replace(b"*text == '\x00'", b"*text == 0")
    path.write_bytes(data)

remaining = path.read_bytes().count(b'\x00')
if remaining:
    raise SystemExit(f'generated CUDA source still contains {remaining} NUL byte(s)')

text = path.read_text(encoding='utf-8')
if '*text == 0' not in text:
    raise SystemExit('v1.1.0 generated env empty-string check was not normalized')

print(f'V110_GENERATED_NUL_FIXED={count}')
print('V110_GENERATED_SOURCE_SANITIZE=PASS')
