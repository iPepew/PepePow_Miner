#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: restore_v104_pool_contract.py <main.cpp> <target.cpp>")

main_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
main = main_path.read_text()
target = target_path.read_text()

# Restore only the v1.0.4 pool-facing semantics that are independently
# supported by the historical accepted-share fix: numeric nonce word and
# wire difficulty / 65536. Keep the later standard 0xffff diff1 target.
# The combination old diff1 target + /65536 was proven by recovery testing to
# be far too permissive on the current pool (thousands of low-difficulty rejects).
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
    // v1.0.4 accepted-share contract: submit nonce as an eight-digit numeric
    // hex word. Do not byte-swap the numeric scan nonce before mining.submit.
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
    '// PEPEW pool wire difficulty is scaled by 65,536. This behavior was\n'
    '// introduced by the known accepted-share fix fe0f92c and is retained.\n'
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

# Keep the later standard diff1 target. Foztor's observed accepted-share cadence
# at pool difficulty 327.68 is consistent with this target combined with /65536.
standard_diff1 = '''constexpr std::array<std::uint8_t, 32> kDiff1Target{
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
'''
if standard_diff1 not in target:
    raise SystemExit("expected standard diff1 target missing")

main_path.write_text(main)
target_path.write_text(target)
print("restored hybrid pool contract: numeric nonce + wire difficulty /65536; kept standard diff1 target")
