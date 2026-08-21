#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: restore_v104_pool_contract.py <main.cpp> <target.cpp>")

main_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
main = main_path.read_text()
target = target_path.read_text()

# v1.0.4 was tested as a share-producing release. Restore its pool-facing
# contract exactly before doing any further V100 performance work.
old_nonce = '''std::string encode_submit_nonce(std::uint32_t value) {
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0');
    for (unsigned shift = 0; shift < 32; shift += 8) {
        stream << std::setw(2) << ((value >> shift) & 0xffU);
    }
    return stream.str();
}
'''
new_nonce = '''std::string encode_submit_nonce(std::uint32_t value) {
    // Proven v1.0.4 wire contract: submit the nonce as an eight-digit numeric
    // hex word. The PEPEW pool interprets this word according to its Stratum
    // header serialization rules.
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0')
           << std::setw(8) << value;
    return stream.str();
}
'''
if old_nonce not in main:
    raise SystemExit("nonce encoder marker missing")
main = main.replace(old_nonce, new_nonce, 1)

stats_marker = 'constexpr auto kStatsInterval = std::chrono::seconds(5);\n'
if stats_marker not in main:
    raise SystemExit("stats marker missing")
main = main.replace(
    stats_marker,
    stats_marker +
    '// Proven v1.0.4 PEPEW Stratum contract: the pool advertises difficulty\n'
    '// multiplied by 65,536. Mining target generation must use the effective\n'
    '// difficulty, not the raw wire value.\n'
    'constexpr double kPepepowWireDifficultyScale = 65536.0;\n',
    1,
)

old_target_call = '                const auto target = pepepow::mining::target_from_difficulty(item.stratum_job.difficulty);\n'
new_target_call = '''                const double effective_difficulty =
                    item.stratum_job.difficulty / kPepepowWireDifficultyScale;
                const auto target = pepepow::mining::target_from_difficulty(effective_difficulty);
'''
if old_target_call not in main:
    raise SystemExit("difficulty target marker missing")
main = main.replace(old_target_call, new_target_call, 1)

old_log = '''                                  << " difficulty=" << item.stratum_job.difficulty
                                  << " extranonce2=" << extranonce2
'''
new_log = '''                                  << " wire_difficulty=" << item.stratum_job.difficulty
                                  << " effective_difficulty=" << effective_difficulty
                                  << " extranonce2=" << extranonce2
'''
if old_log not in main:
    raise SystemExit("difficulty log marker missing")
main = main.replace(old_log, new_log, 1)

# Restore the exact v1.0.4 difficulty-1 target. A later optimization branch
# shifted the 0xffff word by 16 bits and silently changed share difficulty.
old_diff1 = '''constexpr std::array<std::uint8_t, 32> kDiff1Target{
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
'''
new_diff1 = '''constexpr std::array<std::uint8_t, 32> kDiff1Target{
    0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
'''
if old_diff1 not in target:
    raise SystemExit("diff1 target marker missing")
target = target.replace(old_diff1, new_diff1, 1)
target = target.replace(
    '// Standard 0xffff difficulty-1 target used by PEPEPOW/HooHashV110.\n'
    '// Big-endian: 00000000ffff0000... (not 0000ffff0000...).\n',
    '// Restored from verified v1.0.4 pool contract.\n'
    '// Big-endian: 0000ffff00000000...\n',
    1,
)

main_path.write_text(main)
target_path.write_text(target)
print("restored v1.0.4 pool contract: nonce word, wire difficulty /65536, diff1 target")
