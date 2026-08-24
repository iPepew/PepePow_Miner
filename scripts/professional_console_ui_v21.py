#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
main_cpp = ROOT / "native/src/app/main.cpp"
h_run = ROOT / "hiveos/h-run.sh"

text = main_cpp.read_text(encoding="utf-8")

console_ui = r'''class ConsoleUi {
public:
    static void banner(std::string_view gpu_name) {
        std::cout
            << kBrightGreen << "============================================================\n" << kReset
            << "                       " << kBold << kGreen << "PEPEW MINER" << kReset << "\n"
            << kBrightGreen << "============================================================\n" << kReset
            << kCyan << "Version   : " << kReset << "v" << PEPEPOW_VERSION << '\n'
            << kCyan << "Algorithm : " << kReset << "HooHash V110\n"
            << kCyan << "GPU       : " << kReset << gpu_name << '\n'
            << kCyan << "Channel   : " << kReset << "BETA\n"
            << kBrightGreen << "------------------------------------------------------------\n" << kReset
            << kYellow << "PepeW — твоя монета. Твои правила.\n" << kReset
            << kBrightGreen << "============================================================\n\n" << kReset
            << std::flush;
    }

    static void render(std::string_view message) {
        if (message.starts_with("BUILD_ID ") || message.starts_with("JOB ") ||
            message.starts_with("JOB_HEADER ") || message.starts_with("CANDIDATE ") ||
            message.starts_with("SHARE_TRACE ") || message.starts_with("SUBMIT ")) {
            return;
        }

        if (message.starts_with("POOL_REFERENCE ")) {
            std::cout << kMagenta << "[HOOHASH]" << kReset
                      << "  Consensus V110 verified\n";
            return;
        }
        if (message.starts_with("STRATUM Connected to ")) {
            std::cout << kCyan << "[POOL]" << kReset << "     Connected\n";
            return;
        }
        if (message.starts_with("STRATUM Stratum subscribed:")) {
            std::cout << kCyan << "[POOL]" << kReset << "     Subscribed\n";
            return;
        }
        if (message.starts_with("STRATUM Stratum authorized:")) {
            std::cout << kBrightGreen << "[READY]" << kReset << "    Pool authorization complete\n";
            return;
        }
        if (message.starts_with("STRATUM Difficulty set to ")) {
            std::cout << kYellow << "[DIFF]" << kReset << "     "
                      << message.substr(std::string_view("STRATUM Difficulty set to ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM New job ")) {
            std::cout << kCyan << "[JOB]" << kReset << "      "
                      << message.substr(std::string_view("STRATUM New job ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM Share accepted:")) {
            std::cout << kBrightGreen << "[ACCEPTED]" << kReset << " "
                      << message.substr(std::string_view("STRATUM Share accepted: ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM Share rejected:")) {
            std::cout << kRed << "[REJECTED]" << kReset << " "
                      << message.substr(std::string_view("STRATUM Share rejected: ").size()) << '\n';
            return;
        }
        if (message.starts_with("HASHRATE ")) {
            const std::string mhs = field_value(message, "mhs=");
            const std::string accepted = field_value(message, "accepted=");
            const std::string rejected = field_value(message, "rejected=");
            const std::string uptime = field_value(message, "uptime=");
            std::cout << kGreen << "[MINING]" << kReset
                      << "  " << kBold << mhs << " MH/s" << kReset
                      << "  |  A " << accepted
                      << "  |  R " << rejected
                      << "  |  UP " << uptime << '\n';
            return;
        }
        if (message.starts_with("WORKER_ERROR ") || message.starts_with("FATAL ")) {
            std::cout << kRed << "[ERROR]" << kReset << "    " << message << '\n';
            return;
        }
        if (message.starts_with("FINAL_STATS ")) {
            std::cout << kDim << "[STOP]     " << message.substr(12) << kReset << '\n';
            return;
        }
    }

    static void fatal(std::string_view message) {
        std::cerr << kRed << "[FATAL]    " << message << kReset << '\n';
    }
};'''

pattern = re.compile(r'class ConsoleUi \{.*?\n\};\n\nclass DiagnosticLog', re.S)
match = pattern.search(text)
if not match:
    raise SystemExit("ConsoleUi block not found")
text = pattern.sub(console_ui + "\n\nclass DiagnosticLog", text, count=1)
main_cpp.write_text(text, encoding="utf-8")

run_text = h_run.read_text(encoding="utf-8")
old = '  echo "PROFILE=$(tr \'\\n\' \' \' < ./BUILD_PROFILE 2>/dev/null || true)"\n'
new = '''  if [[ -r ./BUILD_PROFILE ]]; then
    echo "PROFILE=$(tr '\\n' ' ' < ./BUILD_PROFILE)"
  else
    echo "PROFILE=embedded"
  fi
'''
if old not in run_text:
    raise SystemExit("BUILD_PROFILE line not found")
run_text = run_text.replace(old, new, 1)
h_run.write_text(run_text, encoding="utf-8")

print("Applied professional no-emoji console UI and BUILD_PROFILE fallback")
