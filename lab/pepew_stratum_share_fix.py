#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: pepew_stratum_share_fix.py <native/src/app/main.cpp>")

path = Path(sys.argv[1])
s = path.read_text()

old = """namespace {\npepepow::stratum::Client* active_client = nullptr;\nconstexpr auto kStatsInterval = std::chrono::seconds(5);\n"""
new = """namespace {\npepepow::stratum::Client* active_client = nullptr;\n\n// Foztor PEPEW Stratum exposes mining.set_difficulty in wire units scaled by\n// 65,536. Convert to the effective share difficulty before building target.\n// This pool-facing scale is independent from HooHash consensus/block target.\nconstexpr double kPepepowWireDifficultyScale = 65536.0;\nconstexpr auto kStatsInterval = std::chrono::seconds(5);\n"""
if old not in s:
    raise SystemExit("active-client anchor not found")
s = s.replace(old, new, 1)

old = """std::string encode_submit_nonce(std::uint32_t value) {\n    std::ostringstream stream;\n    stream << std::hex << std::nouppercase << std::setfill('0');\n    for (unsigned shift = 0; shift < 32; shift += 8) {\n        stream << std::setw(2) << ((value >> shift) & 0xffU);\n    }\n    return stream.str();\n}\n"""
new = """std::string encode_submit_nonce(std::uint32_t value) {\n    // Foztor PEPEW pool expects the scan nonce as an eight-digit numeric hex\n    // word. The server serializes that word into the canonical block header.\n    std::ostringstream stream;\n    stream << std::hex << std::nouppercase << std::setfill('0')\n           << std::setw(8) << value;\n    return stream.str();\n}\n"""
if old not in s:
    raise SystemExit("submit nonce function anchor not found")
s = s.replace(old, new, 1)

old = """                const auto target = pepepow::mining::target_from_difficulty(item.stratum_job.difficulty);\n                std::uint64_t extranonce2_counter = 0;\n"""
new = """                const double effective_difficulty =\n                    item.stratum_job.difficulty / kPepepowWireDifficultyScale;\n                const auto target = pepepow::mining::target_from_difficulty(effective_difficulty);\n                std::uint64_t extranonce2_counter = 0;\n"""
if old not in s:
    raise SystemExit("target construction anchor not found")
s = s.replace(old, new, 1)

old = """                        std::cout << \"Mining job \" << mining_job.job_id << \" GPU=\" << device_index_\n                                  << \" difficulty=\" << item.stratum_job.difficulty\n                                  << \" extranonce2=\" << extranonce2\n                                  << \" backend=\" << backend_.name() << '\\n';\n"""
new = """                        std::cout << \"Mining job \" << mining_job.job_id << \" GPU=\" << device_index_\n                                  << \" wire_difficulty=\" << item.stratum_job.difficulty\n                                  << \" effective_difficulty=\" << effective_difficulty\n                                  << \" extranonce2=\" << extranonce2\n                                  << \" backend=\" << backend_.name() << '\\n';\n"""
if old not in s:
    raise SystemExit("mining job log anchor not found")
s = s.replace(old, new, 1)

path.write_text(s)
print("Applied PEPEW Stratum share fix: wire diff /65536 + numeric nonce hex")
