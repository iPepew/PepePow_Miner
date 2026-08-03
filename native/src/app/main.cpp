#include "pepepow/core/backend.hpp"
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#include "pepepow/version.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/cuda/header80_backend.hpp"
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>

namespace {
pepepow::stratum::Client* active_client = nullptr;

constexpr std::string_view kReset = "\033[0m";
constexpr std::string_view kBold = "\033[1m";
constexpr std::string_view kGreen = "\033[32m";
constexpr std::string_view kBrightGreen = "\033[92m";
constexpr std::string_view kCyan = "\033[96m";
constexpr std::string_view kYellow = "\033[93m";
constexpr std::string_view kRed = "\033[91m";
constexpr std::string_view kMagenta = "\033[95m";
constexpr std::string_view kDim = "\033[2m";

std::string now_iso() {
    const auto now = std::chrono::system_clock::now();
    const auto time = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    localtime_r(&time, &tm);
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S");
    return out.str();
}

std::uint64_t epoch_seconds() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

std::string fixed_number(double value, int precision) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(precision) << value;
    return out.str();
}

std::string duration_text(std::uint64_t total_seconds) {
    const auto hours = total_seconds / 3600U;
    const auto minutes = (total_seconds % 3600U) / 60U;
    const auto seconds = total_seconds % 60U;
    std::ostringstream out;
    out << std::setfill('0') << std::setw(2) << hours << ':'
        << std::setw(2) << minutes << ':' << std::setw(2) << seconds;
    return out.str();
}

std::string field_value(std::string_view line, std::string_view key) {
    const auto start = line.find(key);
    if (start == std::string_view::npos) return {};
    const auto value_start = start + key.size();
    const auto end = line.find(' ', value_start);
    return std::string(line.substr(value_start, end == std::string_view::npos
        ? line.size() - value_start : end - value_start));
}

class ConsoleUi {
public:
    static void banner(std::string_view gpu_name) {
        std::cout
            << kBrightGreen << "=========================================\n" << kReset
            << "            🐸 " << kBold << kGreen << "PepeW Miner" << kReset << " 🐸\n"
            << kBrightGreen << "=========================================\n\n" << kReset
            << kCyan << "Version   : " << kReset << "v" << PEPEPOW_VERSION << '\n'
            << kCyan << "Algorithm : " << kReset << "HooHash V110\n"
            << kCyan << "GPU       : " << kReset << gpu_name << "\n\n"
            << kYellow << "\"PepeW — твоя монета. Твои правила.\"\n\n" << kReset
            << kBrightGreen << "=========================================\n" << kReset
            << std::flush;
    }

    static void render(std::string_view message) {
        if (message.starts_with("BUILD_ID ") || message.starts_with("JOB ") ||
            message.starts_with("JOB_HEADER ") || message.starts_with("CANDIDATE ") ||
            message.starts_with("SHARE_TRACE ") || message.starts_with("SUBMIT ")) {
            return;
        }

        if (message.starts_with("POOL_REFERENCE ")) {
            std::cout << kMagenta << "🟣 HOOHASH" << kReset
                      << "   Consensus V110 verified\n";
            return;
        }
        if (message.starts_with("STRATUM Connected to ")) {
            std::cout << kCyan << "🔵 POOL" << kReset << "      Connected\n";
            return;
        }
        if (message.starts_with("STRATUM Stratum subscribed:")) {
            std::cout << kCyan << "🔵 POOL" << kReset << "      Subscribed\n";
            return;
        }
        if (message.starts_with("STRATUM Stratum authorized:")) {
            std::cout << kBrightGreen << "✅ READY" << kReset << "     Pool authorization complete\n";
            return;
        }
        if (message.starts_with("STRATUM Difficulty set to ")) {
            std::cout << kYellow << "🟡 DIFF" << kReset << "      "
                      << message.substr(std::string_view("STRATUM Difficulty set to ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM New job ")) {
            std::cout << kCyan << "🔄 JOB" << kReset << "       "
                      << message.substr(std::string_view("STRATUM New job ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM Share accepted:")) {
            std::cout << kBrightGreen << "💰 ACCEPTED" << kReset << "  "
                      << message.substr(std::string_view("STRATUM Share accepted: ").size()) << '\n';
            return;
        }
        if (message.starts_with("STRATUM Share rejected:")) {
            std::cout << kRed << "❌ REJECTED" << kReset << "  "
                      << message.substr(std::string_view("STRATUM Share rejected: ").size()) << '\n';
            return;
        }
        if (message.starts_with("HASHRATE ")) {
            const std::string mhs = field_value(message, "mhs=");
            const std::string accepted = field_value(message, "accepted=");
            const std::string rejected = field_value(message, "rejected=");
            const std::string uptime = field_value(message, "uptime=");
            std::cout << kGreen << "🐸 🔨 Mining" << kReset
                      << "  •  " << kBold << mhs << " MH/s" << kReset
                      << "  •  💰 A " << accepted
                      << "  •  ❌ R " << rejected
                      << "  •  ⏱ " << uptime << '\n';
            return;
        }
        if (message.starts_with("WORKER_ERROR ") || message.starts_with("FATAL ")) {
            std::cout << kRed << "🔴 ERROR" << kReset << "     " << message << '\n';
            return;
        }
        if (message.starts_with("FINAL_STATS ")) {
            std::cout << kDim << "⚪ STOP      " << message.substr(12) << kReset << '\n';
            return;
        }
    }

    static void fatal(std::string_view message) {
        std::cerr << kRed << "🔴 FATAL     " << message << kReset << '\n';
    }
};

class DiagnosticLog {
public:
    explicit DiagnosticLog(std::string path) : path_(std::move(path)) {
        if (!path_.empty()) {
            const std::filesystem::path p(path_);
            if (p.has_parent_path()) std::filesystem::create_directories(p.parent_path());
            file_.open(path_, std::ios::app);
            if (!file_) throw std::runtime_error("cannot open diagnostic log: " + path_);
        }
    }

    void write(const std::string& message) {
        std::lock_guard lock(mutex_);
        const std::string line = now_iso() + " " + message;
        if (file_) { file_ << line << '\n'; file_.flush(); }
        ConsoleUi::render(message);
        std::cout.flush();
    }

    [[nodiscard]] const std::string& path() const noexcept { return path_; }

private:
    std::string path_;
    std::ofstream file_;
    std::mutex mutex_;
};

class RuntimeStatus {
public:
    explicit RuntimeStatus(std::filesystem::path path)
        : path_(std::move(path)), started_(std::chrono::steady_clock::now()) {}

    [[nodiscard]] std::uint64_t uptime_seconds() const {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - started_).count());
    }

    template <typename Stats>
    void update(std::uint64_t hps, const Stats& stats, std::string_view state) {
        std::lock_guard lock(mutex_);
        const auto temporary = path_.string() + ".tmp";
        {
            std::ofstream output(temporary, std::ios::trunc);
            if (!output) return;
            output << "HPS=" << hps << '\n'
                   << "ACCEPTED=" << stats.accepted << '\n'
                   << "REJECTED=" << stats.rejected << '\n'
                   << "UPTIME=" << uptime_seconds() << '\n'
                   << "UPDATED_EPOCH=" << epoch_seconds() << '\n'
                   << "PID=" << static_cast<unsigned long long>(::getpid()) << '\n'
                   << "STATE=" << state << '\n';
        }
        std::error_code error;
        std::filesystem::rename(temporary, path_, error);
        if (error) {
            std::filesystem::remove(path_, error);
            error.clear();
            std::filesystem::rename(temporary, path_, error);
        }
    }

private:
    std::filesystem::path path_;
    std::chrono::steady_clock::time_point started_;
    std::mutex mutex_;
};

void signal_handler(int) { if (active_client != nullptr) active_client->stop(); }

std::string build_identity() {
    return std::string("PepeW Performance & Stability Edition ") + PEPEPOW_VERSION +
           " commit=" + PEPEPOW_GIT_COMMIT + " build=Release";
}

void print_help() {
    std::cout << build_identity() << "\nUsage:\n"
              << "  pepepowminer -o stratum+tcp://host:port -u wallet.worker [-p x] [--diagnostic]\n\n"
              << "Options:\n"
              << "  -o, --pool URL          Primary Stratum pool\n"
              << "  -O, --pool2 URL         Fallback pool\n"
              << "  -u, --user LOGIN        Wallet or wallet.worker\n"
              << "  -p, --pass PASSWORD     Pool password, default x\n"
              << "      --diagnostic        Enable full job/share diagnostics\n"
              << "      --diagnostic-log P  Diagnostic log path\n"
              << "      --list-gpu          List detected devices and exit\n"
              << "      --version           Show build identity and exit\n"
              << "  -h, --help              Show this help\n";
}

std::string encode_counter_be(std::uint64_t value, std::size_t byte_count) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (std::size_t index = byte_count; index-- > 0;) {
        const auto byte = static_cast<unsigned>((value >> ((index % 8U) * 8U)) & 0xffU);
        stream << std::setw(2) << byte;
    }
    return stream.str();
}

template <typename Container>
std::string hex_of(const Container& value) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (const auto byte : value) stream << std::setw(2) << static_cast<unsigned>(byte);
    return stream.str();
}

std::uint32_t load_le32(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
}

struct WorkItem {
    pepepow::stratum::Job stratum_job;
    std::string extranonce2;
    std::uint64_t generation{0};
};

class MiningWorker {
public:
    MiningWorker(pepepow::MiningBackend& backend, pepepow::stratum::Client& client,
                 DiagnosticLog& log, RuntimeStatus& status, bool diagnostic)
        : backend_(backend), client_(client), log_(log), status_(status), diagnostic_(diagnostic),
          extranonce_counter_(static_cast<std::uint64_t>(
              std::chrono::steady_clock::now().time_since_epoch().count())),
          thread_([this] { run(); }) {}

    ~MiningWorker() { stop(); }
    MiningWorker(const MiningWorker&) = delete;
    MiningWorker& operator=(const MiningWorker&) = delete;

    void set_job(const pepepow::stratum::Job& job) {
        std::lock_guard lock(mutex_);
        const auto counter = extranonce_counter_.fetch_add(1U);
        const std::string extranonce2 = encode_counter_be(counter, job.extranonce2_size);
        latest_ = WorkItem{job, extranonce2, ++generation_};
        condition_.notify_one();
    }

    void stop() {
        bool expected = false;
        if (!stopped_.compare_exchange_strong(expected, true)) return;
        { std::lock_guard lock(mutex_); ++generation_; }
        condition_.notify_all();
        if (thread_.joinable()) thread_.join();
    }

private:
    void run() {
        // 262K keeps the optimized GPU path saturated while reducing stale-job
        // exposure to roughly half of the earlier 524K validation batch.
        constexpr std::uint64_t chunk_size = 262144;
        constexpr double rate_interval_seconds = 3.0;
        auto rate_window_start = std::chrono::steady_clock::now();
        std::uint64_t rate_hashes = 0;

        while (!stopped_.load()) {
            WorkItem item;
            {
                std::unique_lock lock(mutex_);
                condition_.wait(lock, [this] { return stopped_.load() || latest_.has_value(); });
                if (stopped_.load()) break;
                item = *latest_;
                latest_.reset();
            }

            try {
                auto mining_job = pepepow::stratum::build_mining_job(item.stratum_job, item.extranonce2);
                const auto target = pepepow::mining::target_from_difficulty(
                    item.stratum_job.difficulty, mining_job.bits);
                const double normalized = item.stratum_job.difficulty /
                    pepepow::mining::kStratumDifficultyWireScale;
                std::uint64_t nonce = 0;

                log_.write("JOB job=" + mining_job.job_id +
                           " wire_diff=" + std::to_string(item.stratum_job.difficulty) +
                           " normalized_diff=" + std::to_string(normalized) +
                           " xnonce1=" + item.stratum_job.extranonce1 +
                           " xnonce2=" + item.extranonce2 +
                           " version=" + item.stratum_job.version +
                           " nbits=" + item.stratum_job.nbits +
                           " ntime=" + item.stratum_job.ntime +
                           " clean=" + std::to_string(item.stratum_job.clean_jobs) +
                           " target_source=nbits_div_difficulty" +
                           " target_be=" + hex_of(target));

                if (diagnostic_) {
                    auto initial = mining_job;
                    initial.nonce = 0;
                    const auto initial_header = pepepow::build_header80(initial);
                    auto masked_header = initial_header;
                    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
                    log_.write("JOB_HEADER nonce=00000000 header80=" + hex_of(initial_header) +
                               " matrix_seed_blake3=" + hex_of(pepepow::crypto::blake3_hash(masked_header)) +
                               " prevhash_wire=" + item.stratum_job.prevhash +
                               " coinb1=" + item.stratum_job.coinb1 +
                               " coinb2=" + item.stratum_job.coinb2 +
                               " merkle_count=" + std::to_string(item.stratum_job.merkle_branch.size()));
                }

                while (!stopped_.load() && item.generation == generation_.load() &&
                       nonce <= 0xffffffffULL) {
                    const std::uint64_t remaining = 0x100000000ULL - nonce;
                    const std::uint64_t count = remaining < chunk_size ? remaining : chunk_size;
                    const auto candidate = backend_.search(
                        mining_job, pepepow::SearchRange{nonce, count}, target);

                    rate_hashes += count;
                    const auto rate_now = std::chrono::steady_clock::now();
                    const double rate_seconds = std::chrono::duration<double>(
                        rate_now - rate_window_start).count();
                    if (rate_seconds >= rate_interval_seconds) {
                        const double hashes_per_second = static_cast<double>(rate_hashes) / rate_seconds;
                        const auto stats = client_.stats();
                        const std::uint64_t hps = static_cast<std::uint64_t>(hashes_per_second);
                        status_.update(hps, stats, "mining");
                        log_.write("HASHRATE hps=" + std::to_string(hps) +
                                   " khs=" + fixed_number(hashes_per_second / 1000.0, 2) +
                                   " mhs=" + fixed_number(hashes_per_second / 1000000.0, 3) +
                                   " accepted=" + std::to_string(stats.accepted) +
                                   " rejected=" + std::to_string(stats.rejected) +
                                   " uptime=" + duration_text(status_.uptime_seconds()) +
                                   " window_s=" + fixed_number(rate_seconds, 2));
                        rate_hashes = 0;
                        rate_window_start = rate_now;
                    }

                    if (candidate.has_value()) {
                        auto validation_job = mining_job;
                        validation_job.nonce = candidate->nonce;
                        const auto header = pepepow::build_header80(validation_job);
                        const std::string header_hex = hex_of(header);
                        const std::string nonce_header_be = header_hex.substr(76U * 2U, 8U);
                        const std::uint32_t mix_nonce = load_le32(header.data() + 76);
                        const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);
                        const bool gpu_cpu_match = cpu_hash == candidate->hash;
                        const bool target_ok = pepepow::mining::hash_meets_target_be(cpu_hash, target);
                        const std::string nonce_wire =
                            pepepow::stratum::encode_u32_le_hex(candidate->nonce);

                        log_.write("CANDIDATE job=" + item.stratum_job.job_id +
                                   " nonce_u32=" + std::to_string(candidate->nonce) +
                                   " nonce_header_be=" + nonce_header_be +
                                   " nonce_mix_le_u32=" + std::to_string(mix_nonce) +
                                   " nonce_submit_le=" + nonce_wire +
                                   " xnonce2=" + item.extranonce2 +
                                   " gpu_hash=" + hex_of(candidate->hash) +
                                   " cpu_hash=" + hex_of(cpu_hash) +
                                   " match=" + std::to_string(gpu_cpu_match) +
                                   " target_ok=" + std::to_string(target_ok));

                        if (diagnostic_) {
                            log_.write("SHARE_TRACE job=" + item.stratum_job.job_id +
                                       " header80=" + header_hex +
                                       " hash_be=" + hex_of(cpu_hash) +
                                       " target_be=" + hex_of(target) +
                                       " ntime=" + item.stratum_job.ntime +
                                       " nonce_header_be=" + nonce_header_be +
                                       " nonce_mix_le_u32=" + std::to_string(mix_nonce) +
                                       " nonce_submit_le=" + nonce_wire +
                                       " xnonce2=" + item.extranonce2);
                        }

                        if (gpu_cpu_match && target_ok) {
                            pepepow::stratum::Share share{item.stratum_job.job_id,
                                item.extranonce2, item.stratum_job.ntime, nonce_wire};
                            bool sent = false;
                            {
                                // Serialize local job replacement and submit so a
                                // just-received clean job cannot race this boundary.
                                std::lock_guard lock(mutex_);
                                if (item.generation == generation_.load()) {
                                    sent = client_.submit(share);
                                }
                            }
                            log_.write(std::string("SUBMIT job=") + share.job_id +
                                       " sent=" + std::to_string(sent) +
                                       " params=[user," + share.job_id + ',' + share.extranonce2 + ',' +
                                       share.ntime + ',' + share.nonce + "]");
                        }
                    }
                    nonce += count;
                }
            } catch (const std::exception& error) {
                const auto stats = client_.stats();
                status_.update(0, stats, "worker_error");
                log_.write(std::string("WORKER_ERROR ") + error.what());
            }
        }
    }

    pepepow::MiningBackend& backend_;
    pepepow::stratum::Client& client_;
    DiagnosticLog& log_;
    RuntimeStatus& status_;
    bool diagnostic_{false};
    std::mutex mutex_;
    std::condition_variable condition_;
    std::optional<WorkItem> latest_;
    std::atomic_uint64_t generation_{0};
    std::atomic_uint64_t extranonce_counter_{0};
    std::atomic_bool stopped_{false};
    std::thread thread_;
};
} // namespace

int main(int argc, char** argv) {
    try {
        std::string pool, username, password{"x"};
        std::optional<std::string> fallback;
        bool list_gpu = false;
        bool diagnostic = std::getenv("PEPEPOW_DIAGNOSTIC") != nullptr;
        std::string diagnostic_log = std::getenv("PEPEPOW_DIAGNOSTIC_LOG") ?
            std::getenv("PEPEPOW_DIAGNOSTIC_LOG") : "/tmp/pepepow-performance.log";

        for (int index = 1; index < argc; ++index) {
            const std::string argument = argv[index];
            const auto take_value = [&](const char* name) -> std::string {
                if (index + 1 >= argc) {
                    throw std::invalid_argument(std::string("missing value for ") + name);
                }
                return argv[++index];
            };
            if (argument == "-o" || argument == "--pool") pool = take_value("pool");
            else if (argument == "-O" || argument == "--pool2") fallback = take_value("pool2");
            else if (argument == "-u" || argument == "--user") username = take_value("user");
            else if (argument == "-p" || argument == "--pass") password = take_value("pass");
            else if (argument == "--diagnostic") diagnostic = true;
            else if (argument == "--diagnostic-log") diagnostic_log = take_value("diagnostic-log");
            else if (argument == "--list-gpu") list_gpu = true;
            else if (argument == "--version") { std::cout << build_identity() << '\n'; return 0; }
            else if (argument == "--pepepow" || argument == "--no-longpoll") {}
            else if (argument == "-h" || argument == "--help") { print_help(); return 0; }
            else throw std::invalid_argument("unknown argument: " + argument);
        }

        std::unique_ptr<pepepow::MiningBackend> backend;
#ifdef PEPEPOW_HAS_CUDA
        backend = std::make_unique<pepepow::Header80CudaBackend>(0);
#else
        backend = std::make_unique<pepepow::CpuReferenceBackend>();
#endif
        const auto devices = backend->enumerate_devices();
        if (list_gpu) {
            std::cout << build_identity() << '\n';
            for (const auto& device : devices) {
                std::cout << '[' << device.index << "] " << device.name
                          << " sm_" << device.compute_major << device.compute_minor << '\n';
            }
            return 0;
        }
        if (devices.empty()) throw std::runtime_error("no mining device available");
        if (pool.empty() || username.empty()) { print_help(); return 2; }

        ConsoleUi::banner(devices.front().name);
        DiagnosticLog log(diagnostic_log);
        std::filesystem::path status_path(diagnostic_log);
        status_path.replace_filename("miner-status.env");
        RuntimeStatus status(status_path);

        log.write("BUILD_ID " + build_identity() + " diagnostic=" +
                  std::to_string(diagnostic) + " log=" + log.path());
        log.write("POOL_REFERENCE hoohash=V110 matrix_seed=BLAKE3_MASKED_HEADER "
                  "header_nonce=BE32 mix_nonce=LE32 submit_nonce=LE_HEX "
                  "share_target=NBITS_DIV_DIFFICULTY proxy=passive "
                  "gpu_target_filter=1 blake3_midstate=1");

        pepepow::stratum::Config config;
        config.primary = pepepow::stratum::parse_endpoint(pool);
        if (fallback.has_value()) config.fallback = pepepow::stratum::parse_endpoint(*fallback);
        config.username = username;
        config.password = password;
        config.agent = std::string("PepeW/") + PEPEPOW_VERSION;

        pepepow::stratum::Client client(std::move(config));
        client.set_log_handler([&log](const std::string& line) {
            log.write("STRATUM " + line);
        });
        status.update(0, client.stats(), "starting");
        MiningWorker worker(*backend, client, log, status, diagnostic);
        active_client = &client;
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);
        std::signal(SIGPIPE, SIG_IGN);
        client.set_job_handler([&worker](const pepepow::stratum::Job& job) {
            worker.set_job(job);
        });
        client.run();
        worker.stop();
        const auto stats = client.stats();
        status.update(0, stats, "stopped");
        log.write("FINAL_STATS accepted=" + std::to_string(stats.accepted) +
                  " rejected=" + std::to_string(stats.rejected) +
                  " reconnects=" + std::to_string(stats.reconnects));
        active_client = nullptr;
        return 0;
    } catch (const std::exception& error) {
        ConsoleUi::fatal(error.what());
        return 1;
    }
}
