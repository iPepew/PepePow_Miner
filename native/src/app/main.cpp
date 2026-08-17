#include "pepepow/core/backend.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"
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
#include <numeric>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
pepepow::stratum::Client* active_client = nullptr;
constexpr auto kStatsInterval = std::chrono::seconds(5);
std::mutex output_mutex;

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
std::string hash_hex(const pepepow::Hash256& hash) {
    std::ostringstream stream;
    stream << std::hex << std::nouppercase << std::setfill('0');
    for (const auto byte : hash) {
        stream << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return stream.str();
}

std::uint32_t load_le32_host(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
}

void print_kat_stage(
    std::string_view stage,
    const pepepow::Hash256& cpu,
    const pepepow::Hash256& gpu) {
    std::cout << "KAT " << stage << " CPU=" << hash_hex(cpu) << '\n'
              << "KAT " << stage << " GPU=" << hash_hex(gpu) << '\n'
              << "KAT " << stage << ' ' << (cpu == gpu ? "MATCH" : "MISMATCH") << '\n';
}

void run_hoohash_consensus_self_test(pepepow::Header80CudaBackend& backend) {
    // Real PEPEPOW block KAT, height 0x4734dd. Besides the final consensus
    // digest, capture the GPU first BLAKE3 and pre-final mixed buffer. That
    // localizes V100/sm_70 failures without ever allowing an invalid share.
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

    const pepepow::Header80 header = pepepow::build_header80(job);
    pepepow::Header80 masked_header = header;
    masked_header[76] = 0;
    masked_header[77] = 0;
    masked_header[78] = 0;
    masked_header[79] = 0;

    const auto cpu_first = pepepow::crypto::blake3_hash(header);
    const auto matrix_seed = pepepow::crypto::blake3_hash(masked_header);
    const auto cpu_matrix = pepepow::crypto::generate_hoohash_matrix(matrix_seed);
    const auto cpu_nonce = load_le32_host(header.data() + 76);
    const auto cpu_mixed = pepepow::crypto::hoohash_matrix_mix(
        cpu_matrix, cpu_first, cpu_nonce);
    const auto cpu_final = pepepow::crypto::blake3_hash(cpu_mixed);

    const auto gpu = backend.diagnose(job, job.nonce);

    std::cout << "HooHashV110 CUDA KAT diagnostics (real block 0x4734dd)\n";
    print_kat_stage("first_pass", cpu_first, gpu.first_pass);
    print_kat_stage("mixed", cpu_mixed, gpu.mixed);
    print_kat_stage("final", cpu_final, gpu.final_hash);
    std::cout << "KAT expected final=" << hash_hex(expected) << '\n';
    std::cout << "KAT CPU consensus=" << (cpu_final == expected ? "PASS" : "FAIL") << '\n';
    std::cout << "KAT GPU consensus=" << (gpu.final_hash == expected ? "PASS" : "FAIL") << '\n';

    if (gpu.final_hash != expected) {
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
        << "      --kat-only       Run CUDA consensus diagnostics and exit\n"
        << "  -h, --help           Show this help\n";
}

struct WorkItem {
    pepepow::stratum::Job stratum_job;
    std::string extranonce2;
    std::uint64_t generation{0};
};

class MiningStatsRegistry {
public:
    explicit MiningStatsRegistry(std::size_t gpu_count)
        : per_gpu_mhs_(gpu_count, 0.0) {}

    double update(std::size_t slot, double mhs) {
        std::lock_guard lock(mutex_);
        if (slot < per_gpu_mhs_.size()) per_gpu_mhs_[slot] = mhs;
        return std::accumulate(per_gpu_mhs_.begin(), per_gpu_mhs_.end(), 0.0);
    }

private:
    std::mutex mutex_;
    std::vector<double> per_gpu_mhs_;
};

class MiningWorker {
public:
    MiningWorker(
        pepepow::MiningBackend& backend,
        pepepow::stratum::Client& client,
        std::size_t worker_slot,
        int device_index,
        std::size_t worker_count,
        MiningStatsRegistry& stats_registry)
        : backend_(backend),
          client_(client),
          worker_slot_(worker_slot),
          device_index_(device_index),
          worker_count_(worker_count),
          stats_registry_(stats_registry),
          thread_([this] { run(); }) {}

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

    void emit_stats(double megahashes_per_second, std::string_view state) {
        const auto now = Clock::now();
        const auto uptime = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::seconds>(now - started_at_).count());
        const auto pool_stats = client_.stats();
        const double total_mhs = stats_registry_.update(worker_slot_, megahashes_per_second);

        std::ostringstream gpu_line;
        gpu_line << std::fixed << std::setprecision(3)
                 << "[GPU" << device_index_ << "] " << megahashes_per_second << " MH/s"
                 << " | A " << pool_stats.accepted
                 << " | R " << pool_stats.rejected
                 << " | UP " << format_uptime(uptime)
                 << " | REC " << pool_stats.reconnects
                 << " | STATE " << state;

        std::ostringstream total_line;
        total_line << std::fixed << std::setprecision(3)
                   << "[MINING] " << total_mhs << " MH/s"
                   << " | A " << pool_stats.accepted
                   << " | R " << pool_stats.rejected
                   << " | UP " << format_uptime(uptime)
                   << " | REC " << pool_stats.reconnects
                   << " | STATE " << state;

        std::lock_guard output_lock(output_mutex);
        std::cout << gpu_line.str() << '\n' << total_line.str() << '\n';
    }

    void run() {
        constexpr std::uint64_t chunk_size = 65536;
        const std::uint64_t nonce_stride = chunk_size * static_cast<std::uint64_t>(worker_count_);
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
                std::uint64_t nonce = static_cast<std::uint64_t>(worker_slot_) * chunk_size;

                {
                    std::lock_guard output_lock(output_mutex);
                    std::cout << "Mining job " << mining_job.job_id
                              << " GPU=" << device_index_
                              << " difficulty=" << item.stratum_job.difficulty
                              << " backend=" << backend_.name() << '\n';
                }

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
                    nonce += nonce_stride;
                }
            } catch (const std::exception& error) {
                std::lock_guard output_lock(output_mutex);
                std::cerr << "GPU " << device_index_ << " worker error: " << error.what() << '\n';
            }
        }
    }

    pepepow::MiningBackend& backend_;
    pepepow::stratum::Client& client_;
    std::size_t worker_slot_{0};
    int device_index_{0};
    std::size_t worker_count_{1};
    MiningStatsRegistry& stats_registry_;
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
        bool kat_only = false;

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
            else if (argument == "--kat-only") kat_only = true;
            else if (argument == "--pepepow" || argument == "--no-longpoll") {}
            else if (argument == "-h" || argument == "--help") { print_help(); return 0; }
            else throw std::invalid_argument("unknown argument: " + argument);
        }

        std::vector<std::unique_ptr<pepepow::MiningBackend>> backends;
        std::vector<pepepow::DeviceInfo> devices;

#ifdef PEPEPOW_HAS_CUDA
        pepepow::Header80CudaBackend probe(0);
        devices = probe.enumerate_devices();
#else
        auto cpu_backend = std::make_unique<pepepow::CpuReferenceBackend>();
        devices = cpu_backend->enumerate_devices();
#endif

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
        backends.reserve(devices.size());
        for (const auto& device : devices) {
            backends.emplace_back(std::make_unique<pepepow::Header80CudaBackend>(device.index));
        }

        for (std::size_t i = 0; i < backends.size(); ++i) {
            std::cout << "Running HooHashV110 consensus KAT on GPU " << devices[i].index
                      << " (" << devices[i].name << ")\n";
            run_hoohash_consensus_self_test(
                static_cast<pepepow::Header80CudaBackend&>(*backends[i]));
        }
        if (kat_only) return 0;
#else
        backends.emplace_back(std::move(cpu_backend));
        if (kat_only) throw std::runtime_error("--kat-only requires a CUDA build");
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
        MiningStatsRegistry stats_registry(backends.size());
        std::vector<std::unique_ptr<MiningWorker>> workers;
        workers.reserve(backends.size());
        for (std::size_t i = 0; i < backends.size(); ++i) {
            workers.emplace_back(std::make_unique<MiningWorker>(
                *backends[i],
                client,
                i,
                devices[i].index,
                backends.size(),
                stats_registry));
        }

        active_client = &client;
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);

        client.set_job_handler([&workers](const pepepow::stratum::Job& job) {
            for (auto& worker : workers) worker->set_job(job);
        });

        client.run();
        for (auto& worker : workers) worker->stop();
        active_client = nullptr;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Fatal: " << error.what() << '\n';
        return 1;
    }
}