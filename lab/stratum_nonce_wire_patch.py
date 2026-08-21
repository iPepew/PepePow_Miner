#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: stratum_nonce_wire_patch.py <main.cpp>')

p = Path(sys.argv[1])
s = p.read_text()
old = '''std::string encode_submit_nonce(std::uint32_t value) {
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0');
    for (unsigned shift = 0; shift < 32; shift += 8) {
        stream << std::setw(2) << ((value >> shift) & 0xffU);
    }
    return stream.str();
}
'''
new = '''std::string encode_submit_nonce(std::uint32_t value) {
    // HooHashV110 serializes the scan nonce into header[76..79] in big-endian
    // byte order (see build_header80). Stratum mining.submit must send those
    // exact four header bytes. The previous implementation reversed them,
    // so the pool reconstructed a different header and reported low-difficulty
    // shares even when our strict local hash met the target.
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0')
           << std::setw(8) << value;
    return stream.str();
}
'''
if old not in s:
    raise SystemExit('encode_submit_nonce marker missing')
s = s.replace(old, new, 1)
p.write_text(s)
print('patched Stratum nonce wire order')
