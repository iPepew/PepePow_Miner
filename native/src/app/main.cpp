#include "pepepow/core/backend.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/cuda/header80_backend.hpp"
#endif

#include <array>
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

void signal_handler(int) {
    if (active_client != nullptr) active_client->stop();
}

std::string encode_submit_nonce(std::uint32_t value) {
    // Standard Stratum submits the scan nonce as the four little-endian bytes
    // rendered as hex (ccminer: le32enc + bin2hex).
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0');
    for (unsigned shift = 0; shift < 32; shift += 8) {
        stream << std::setw(2) << ((value >> shift) & 0xffU);
    }
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

#ifdef PEPEPOW_HAS_CUDA
void run_hoohash_consensus_self_test(pepepow::MiningBackend& backend) {
    // Real PEPEPOW block KAT, height 0x4734dd. This validates the actual CUDA
    // mining path (header byte order, matrix seed, FP behavior and final digest)
    // on the installed GPU before any pool work is accepted.
    pepepow::MiningJob job;
    job.job_id = "hoohash-v110-real-block-kat";
    job.version = 0x20004000U;
    job.previous_hash = {
        0xdf,0x13,0xf8,0xc7,0x24,0x3b,0x6b,0x22,
        0x6c,0x33,0x99,0xf4,0x85,0xe9,0x02,0x34,
        0x7e,0x41,0xba,0x37,0x0e,0x0c,0x8f,0xea,
        0x75,0x67,0x2f,0x45,0x01,0x00,0x00,0x00};
    job.merkle_root = {
        0x22,0xda,0x19,0x46,0xe7,0xdb,0xa6,0x53,
        0x52,0xae,0x0f,0x65,0xce,0x77,0xdc,0xff,
        0x51,0x05,0xe2,0xf4,0x6a,0x44,0x3e,0x3a,
        0x86,0xbb,0x35,0x9b,0xb6,0x78,0x8b,0xf9};
    job.ntime = 0x6a41a262U;
    job.bits = 0x1d01ce33U;
    job.nonce = 0x4d94e755U;

    constexpr pepepow::Hash256 expected{
        0x00,0x00,0x00,0x01,0x3e,0x74,0xaa,0xd7,
        0x1e,0x79,0xfd,0x0e,0x33,0x03,0xc5,0x14,
        0xaf,0x06,0xbc,0x1b,0x9f,0x26,0xd6,0xa9,
        0x94,0xb6,0x5e,0xb6,0x6d,0x17,0x84,0x5d};
    constexpr pepepow::Hash256 maximum_target = [] {
        pepepow::Hash256 value{};
        value.fill(0xffU);
        return value;
    }();

    const auto result = backend.search(
        job, pepepow::SearchRange{job.nonce, 1U}, maximum_target);
    if (!result.has_value() || result->nonce != job.nonce || result->hash != expected) {
        throw std::runtime_error(
            "HooHashV110 CUDA consensus self-test FAILED; refusing to mine");
    }
    std::cout << "HooHashV110 CUDA consensus self-test: PASS\n";
}
#endif

void print_help() {
    std::cout
        << "PepePowMiner v0.1.3\n"
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

    void emit_stats(double megahashes_per_second, std::string_view state) const {
        const auto now = Clock::now();
        const auto uptime = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::seconds>(now - started_at_).count());
        const auto pool_stats = client_.stats();

        std::ostringstream line;
        line << std::fixed << std::setprecision(3)
             << "[MINING] " << megahashes_per_second << " MH/s"
             << " | A " << pool_stats.accepted
             << " | R " << pool_stats.rejected
             << " | UP " << format_uptime(uptime)
             << " | REC " << pool_stats.reconnects
             << " | STATE " << state;
        std::cout << line.str() << '\n';
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
                // PEPEPOW/HooHashV110 uses the pool's Stratum difficulty directly
                // with the standard 0xffff diff1 target. No 65,536 scale factor.
                const auto target = pepepow::mining::target_from_difficulty(item.stratum_job.difficulty);
                std::uint64_t nonce = 0;

                std::cout << "Mining job " << mining_job.job_id
                          << " difficulty=" << item.stratum_job.difficulty
                          << " backend=" << backend_.name() << '\n';

                while (!stopped_.load() && item.generation == generation_.load() && nonce <= 0xffffffffULL) {
                    if (!client_.connected()) {
                        emit_stats(0.0, "disconnected");
                        stats_window_active = false;
                        stats_window_hashes = 0;
                        break;
                    }

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
                        const double mhs = static_cast<double>(stats_window_hashes) / seconds / 1'000'000.0;
                        emit_stats(mhs, "online");
                        stats_window_start = now;
                        stats_window_hashes = 0;
                    }

                    if (candidate.has_value()) {
                        pepepow::stratum::Share share;
                        share.job_id = item.stratum_job.job_id;
                        share.extranonce2 = item.extranonce2;
                        share.ntime = item.stratum_job.ntime;
                        share.nonce = encode_submit_nonce(candidate->nonce);
                        if (!client_.submit(share)) {
                            emit_stats(0.0, "disconnected");
                            stats_window_active = false;
                            stats_window_hashes = 0;
                            break;
                        }
                    }
                    nonce += count;
                }
            } catch (const std::exception& error) {
                std::cerr << "Worker error: " << error.what() << '\n';
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
    const Clock::time_point started_at_{Clock::now()};
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

#ifdef PEPEPOW_HAS_CUDA
        run_hoohash_consensus_self_test(*backend);
#endif

        if (pool.empty() || username.empty()) {
            print_help();
            return 2;
        }

        pepepow::stratum::Config config;
        config.primary = pepepow::stratum::parse_endpoint(pool);
        if (fallback.has_value()) config.fallback = pepepow::stratum::parse_endpoint(*fallback);
        config.username = username;
        config.password = password;
        config.agent = "PepePowMiner/0.1.3";

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
