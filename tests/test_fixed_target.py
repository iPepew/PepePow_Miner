"""Compile actual target.cpp; compare it to independent integer arithmetic."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
probe = r'''
#include "pepepow/mining/target.hpp"
#include <iostream>
#include <iomanip>
int main() {
  double d;
  while (std::cin >> d) {
    try {
      auto t = pepepow::mining::target_from_fixed_difficulty(d);
      for (auto b : t) std::cout << std::hex << std::setw(2) << std::setfill('0') << unsigned(b);
      std::cout << '\n';
    } catch (...) { std::cout << "INVALID\n"; }
  }
}
'''
with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / 'probe.cpp'
    binary = pathlib.Path(directory) / 'probe'
    source.write_text(probe)
    subprocess.run(['g++', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(root / 'native/include'), str(source),
                    str(root / 'native/src/mining/target.cpp'), '-o', str(binary)],
                   check=True, timeout=30)
    # Binary-exact fractions avoid ambiguous decimal-to-double test boundaries.
    cases = [65536 * (2.0 ** exponent) for exponent in range(-12, 24)]
    values = cases + [0, -1]
    output = subprocess.run([str(binary)], input='\n'.join(map(str, values)),
                            text=True, capture_output=True, check=True, timeout=5)
    lines = output.stdout.splitlines()
    assert len(lines) == len(values)
    for d, line in zip(cases, lines):
        num, den = (d / 65536).as_integer_ratio()
        # Production intentionally rounds its fixed-point denominator upward.
        rounded = (num * 10**12 + den - 1) // den
        expected = min((1 << 256) - 1, (0xffff << 208) * 10**12 // rounded)
        assert int(line, 16) == expected, (d, line, hex(expected))
    assert lines[-2:] == ['INVALID', 'INVALID']
print('PASS: 36 independent fixed-target vectors and 2 invalid inputs')
