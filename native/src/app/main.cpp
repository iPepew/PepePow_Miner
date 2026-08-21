#include "pepepow/core/backend.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/cuda/header80_backend.hpp"
#endif

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <exception>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
pepepow::stratum::Client* active_client = nullptr;
constexpr auto kStatsInterval = std::chrono::seconds(5);

// Proven pool-facing behavior from the share-producing v1.0.4 line.
// PEPEPOW's pool wire difficulty is scaled by 65,536 before transmission.
constexpr double kPepepowWireDifficultyScale = 65536.0;

void signal_handler(int) {
    if (active_client != nullptr) active_client->stop();
}

std::string encode_submit_word(std::uint32_t value) {
    // Keep the exact v1.0.4 submit representation: an eight-digit numeric
    // hexadecimal word. The pool handles the header-byte serialization.
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0') << std::setw(8) << value;
    return stream.str();
}

std::string format_uptime(std::uint64_t total_seconds) {
    const auto hours = total_seconds / 3600U;
    const auto minutes = (total_seconds % 3600U) / 60U;
    const auto seconds = total_seconds % 60U;
    std::ostringstream stream;
    stream << std::setfill('0') << std::setw(2) << hours << ':'
           << std::setw(2) << minutes << ':' << std::setw(2) << seconds;
    return stream.str();
}

void print_help() {
    std::cout
        << "PepePowMiner v1.0.4-recovery\n"
        << "Usage:\n"
        << "  pepepowminer -o stratum+tcp://host:port -u wallet.worker [-p x]\n\n"
        << "Options:\n"
        << "  -o, --pool URL       Primary Stratum pool\n"
        << "  -O, --pool2 URL      Fallback pool (reserved for failover)\n"
        << "  -u, --user LOGIN     Wallet or wallet.worker\n"
        << "  -p, --pass PASSWORD  Pool password, default x\n"
        << "      --pepepow        Select PEPEPOW/HooHash V110 mode\n"
        << "      --list-gpu       List detected devices and exit\n"
        << "  -h, --help           Show this help\n";
}

struct WorkItem {
    pepepow::stratum::Job stratum_job;
    std::string extranonce2;
    std::uint64_t generation{0};
};

class MiningWorker {
public:
    MiningWorker(pepepow::MiningBackend& backend, pepepow::stratum::Client& client)
        : backend_(backend), client_(client), thread_([this] { run(); }) {}

    ~MiningWorker() { stop(); }

    MiningWorker(const MiningWorker&) = delete;
    MiningWorker& operator=(const MiningWorker&) = delete;

    void set_job(const pepepow::stratum::Job& job) {
        std::lock_guard lock(mutex_);
        const std::string extranonce2(job.extranonce2_size * 2U, '0');
        latest_ = WorkItem{job, extranonce2, ++generation_};
        condition_.notify_one();
    }

    void stop() {
        bool expected = false;
        if (!stopped_.compare_exchange_strong(expected, true)) return;
        {
            std::lock_guard lock(mutex_);
            ++generation_;
        }
        condition_.notify_all();
        if (thread_.joinable()) thread_.join();
    }

private:
    using Clock = std::chrono::steady_clock;

    void emit_stats(double mhs, std::string_view state) {
        const auto now = Clock::now();
        const auto uptime = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::seconds>(now - started_at_).count());
        const auto pool_stats = client_.stats();

        std::cout << std::fixed << std::setprecision(3)
                  << "[GPU0] " << mhs << " MH/s"
                  << " | A " << pool_stats.accepted
                  << " | R " << pool_stats.rejected
                  << " | UP " << format_uptime(uptime)
                  << " | REC " << pool_stats.reconnects
                  << " | STATE " << state << '\n'
                  << "[MINING] " << mhs << " MH/s"
                  << " | A " << pool_stats.accepted
                  << " | R " << pool_stats.rejected
                  << " | UP " << format_uptime(uptime)
                  << " | REC " << pool_stats.reconnects
                  << " | STATE " << state << '\n';
    }

    void run() {
        constexpr std::uint64_t chunk_size = 65536;
        bool stats_window_active = false;
        std::uint64_t stats_window_hashes = 0;
        Clock::time_point stats_window_start{};

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
                const double effective_difficulty =
                    item.stratum_job.difficulty / kPepepowWireDifficultyScale;
                const auto target = pepepow::mining::target_from_difficulty(effective_difficulty);
                std::uint64_t nonce = 0;

                std::cout << "Mining job " << mining_job.job_id
                          << " wire_difficulty=" << item.stratum_job.difficulty
                          << " effective_difficulty=" << effective_difficulty
                          << " extranonce2=" << item.extranonce2
                          << " backend=" << backend_.name() << '\n';

                stats_window_active = false;
                stats_window_hashes = 0;

                while (!stopped_.load() && item.generation == generation_.load() && nonce <= 0xffffffffULL) {
                    if (!stats_window_active) {
                        stats_window_start = Clock::now();
                        stats_window_hashes = 0;
                        stats_window_active = true;
                    }

                    const std::uint64_t remaining = 0x100000000ULL - nonce;
                    const std::uint64_t count = remaining < chunk_size ? remaining : chunk_size;
                    const auto candidate = backend_.search(
                        mining_job,
                        pepepow::SearchRange{nonce, count},
                        target);
                    stats_window_hashes += count;

                    const auto now = Clock::now();
                    const auto elapsed = now - stats_window_start;
                    if (elapsed >= kStatsInterval) {
                        const double seconds = std::chrono::duration<double>(elapsed).count();
                        emit_stats(static_cast<double>(stats_window_hashes) / seconds / 1'000'000.0, "online");
                        stats_window_start = now;
                        stats_window_hashes = 0;
                    }

                    if (candidate.has_value()) {
                        pepepow::stratum::Share share;
                        share.job_id = item.stratum_job.job_id;
                        share.extranonce2 = item.extranonce2;
                        share.ntime = item.stratum_job.ntime;
                        share.nonce = encode_submit_word(candidate->nonce);
                        std::cout << "Share candidate nonce_u32=" << candidate->nonce
                                  << " nonce_wire=" << share.nonce << '\n';
                        client_.submit(share);
                    }
                    nonce += count;
                }
            } catch (const std::exception& error) {
                std::cerr << "Worker error: " << error.what() << '\n';
                emit_stats(0.0, "error");
            }
        }
    }

    pepepow::MiningBackend& backend_;
    pepepow::stratum::Client& client_;
    std::mutex mutex_;
    std::condition_variable condition_;
    std::optional<WorkItem> latest_;
    std::atomic_uint64_t generation_{0};
    std::atomic_bool stopped_{false};
    Clock::time_point started_at_{Clock::now()};
    std::thread thread_;
};
} // namespace

int main(int argc, char** argv) {
    try {
        std::cout.setf(std::ios::unitbuf);
        std::cerr.setf(std::ios::unitbuf);

        std::string pool;
        std::optional<std::string> fallback;
        std::string username;
        std::string password{"x"};
        bool list_gpu = false;

        for (int index = 1; index < argc; ++index) {
            const std::string argument = argv[index];
            const auto take_value = [&](const char* name) -> std::string {
                if (index + 1 >= argc) throw std::invalid_argument(std::string("missing value for ") + name);
                return argv[++index];
            };

            if (argument == "-o" || argument == "--pool") pool = take_value("pool");
            else if (argument == "-O" || argument == "--pool2") fallback = take_value("pool2");
            else if (argument == "-u" || argument == "--user") username = take_value("user");
            else if (argument == "-p" || argument == "--pass") password = take_value("pass");
            else if (argument == "--list-gpu") list_gpu = true;
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
            for (const auto& device : devices) {
                std::cout << '[' << device.index << "] " << device.name;
                if (device.compute_major > 0) {
                    std::cout << " sm_" << device.compute_major << device.compute_minor;
                }
                std::cout << '\n';
            }
            return 0;
        }
        if (devices.empty()) throw std::runtime_error("no mining device available");

        if (pool.empty() || username.empty()) {
            print_help();
            return 2;
        }

        pepepow::stratum::Config config;
        config.primary = pepepow::stratum::parse_endpoint(pool);
        if (fallback.has_value()) config.fallback = pepepow::stratum::parse_endpoint(*fallback);
        config.username = username;
        config.password = password;
        config.agent = "PepePowMiner/1.0.4-recovery";

        pepepow::stratum::Client client(std::move(config));
        MiningWorker worker(*backend, client);
        active_client = &client;
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);

        client.set_job_handler([&worker](const pepepow::stratum::Job& job) {
            worker.set_job(job);
        });

        client.run();
        worker.stop();
        active_client = nullptr;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Fatal: " << error.what() << '\n';
        return 1;
    }
}
