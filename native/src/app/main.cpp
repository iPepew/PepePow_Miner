#include "pepepow/core/backend.hpp"
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
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

void signal_handler(int) {
    if (active_client != nullptr) active_client->stop();
}

void print_help() {
    std::cout
        << "PepePowMiner v0.1.7\n"
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

std::string encode_counter_be(std::uint64_t value, std::size_t byte_count) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (std::size_t index = byte_count; index-- > 0;) {
        const auto byte = static_cast<unsigned>((value >> ((index % 8U) * 8U)) & 0xffU);
        stream << std::setw(2) << byte;
    }
    return stream.str();
}

std::string hash_hex(const pepepow::Hash256& hash) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (const auto byte : hash) stream << std::setw(2) << static_cast<unsigned>(byte);
    return stream.str();
}

struct WorkItem {
    pepepow::stratum::Job stratum_job;
    std::string extranonce2;
    std::uint64_t generation{0};
};

class MiningWorker {
public:
    MiningWorker(pepepow::MiningBackend& backend, pepepow::stratum::Client& client)
        : backend_(backend), client_(client),
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
        {
            std::lock_guard lock(mutex_);
            ++generation_;
        }
        condition_.notify_all();
        if (thread_.joinable()) thread_.join();
    }

private:
    void run() {
        constexpr std::uint64_t chunk_size = 4096;
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
                const auto target = pepepow::mining::target_from_difficulty(item.stratum_job.difficulty);
                const double normalized_difficulty =
                    item.stratum_job.difficulty / pepepow::mining::kStratumDifficultyWireScale;
                std::uint64_t nonce = 0;

                std::cout << "Mining job " << mining_job.job_id
                          << " wire-difficulty=" << item.stratum_job.difficulty
                          << " normalized-difficulty=" << std::fixed << std::setprecision(8)
                          << normalized_difficulty
                          << " extranonce2=" << item.extranonce2
                          << " backend=" << backend_.name() << '\n';

                while (!stopped_.load() && item.generation == generation_.load() && nonce <= 0xffffffffULL) {
                    const std::uint64_t remaining = 0x100000000ULL - nonce;
                    const std::uint64_t count = remaining < chunk_size ? remaining : chunk_size;
                    const auto candidate = backend_.search(
                        mining_job,
                        pepepow::SearchRange{nonce, count},
                        target);

                    if (candidate.has_value()) {
                        auto validation_job = mining_job;
                        validation_job.nonce = candidate->nonce;
                        const auto header = pepepow::build_header80(validation_job);
                        const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);

                        if (cpu_hash != candidate->hash) {
                            std::cerr << "CUDA candidate failed CPU hash equality: nonce="
                                      << candidate->nonce
                                      << " gpu=" << hash_hex(candidate->hash)
                                      << " cpu=" << hash_hex(cpu_hash) << '\n';
                        } else if (!pepepow::mining::hash_meets_target_be(cpu_hash, target)) {
                            std::cerr << "CUDA candidate failed CPU target validation: nonce="
                                      << candidate->nonce
                                      << " hash=" << hash_hex(cpu_hash) << '\n';
                        } else if (item.generation == generation_.load()) {
                            pepepow::stratum::Share share;
                            share.job_id = item.stratum_job.job_id;
                            share.extranonce2 = item.extranonce2;
                            share.ntime = item.stratum_job.ntime;
                            share.nonce = pepepow::stratum::encode_u32_le_hex(candidate->nonce);
                            std::cout << "Validated share candidate nonce=" << share.nonce
                                      << " xnonce2=" << share.extranonce2
                                      << " hash=" << hash_hex(cpu_hash) << '\n';
                            client_.submit(share);
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
    std::atomic_uint64_t extranonce_counter_{0};
    std::atomic_bool stopped_{false};
    std::thread thread_;
};
} // namespace

int main(int argc, char** argv) {
    try {
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
        config.agent = "PepePowMiner/0.1.7";

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
