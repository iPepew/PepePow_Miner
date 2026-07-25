#include "pepepow/core/backend.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"

#include <atomic>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <exception>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace {
pepepow::stratum::Client* active_client = nullptr;

void signal_handler(int) {
    if (active_client != nullptr) active_client->stop();
}

void print_help() {
    std::cout
        << "PepePowMiner v0.1.1-rc1\n"
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
    void run() {
        constexpr std::uint64_t chunk_size = 4096;
        while (!stopped_) {
            WorkItem item;
            {
                std::unique_lock lock(mutex_);
                condition_.wait(lock, [this] { return stopped_ || latest_.has_value(); });
                if (stopped_) break;
                item = *latest_;
                latest_.reset();
            }

            try {
                auto mining_job = pepepow::stratum::build_mining_job(item.stratum_job, item.extranonce2);
                const auto target = pepepow::mining::target_from_difficulty(item.stratum_job.difficulty);
                std::uint64_t nonce = 0;

                std::cout << "Mining job " << mining_job.job_id
                          << " difficulty=" << item.stratum_job.difficulty
                          << " backend=" << backend_.name() << '\n';

                while (!stopped_ && item.generation == generation_.load() && nonce <= 0xffffffffULL) {
                    const std::uint64_t remaining = 0x100000000ULL - nonce;
                    const std::uint64_t count = remaining < chunk_size ? remaining : chunk_size;
                    const auto candidate = backend_.search(
                        mining_job,
                        pepepow::SearchRange{nonce, count},
                        target);

                    if (candidate.has_value()) {
                        pepepow::stratum::Share share;
                        share.job_id = item.stratum_job.job_id;
                        share.extranonce2 = item.extranonce2;
                        share.ntime = item.stratum_job.ntime;
                        share.nonce = pepepow::stratum::encode_u32_le_hex(candidate->nonce);
                        std::cout << "Share candidate nonce=" << share.nonce << '\n';
                        client_.submit(share);
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

        pepepow::CpuReferenceBackend backend;
        const auto devices = backend.enumerate_devices();
        if (list_gpu) {
            for (const auto& device : devices) std::cout << '[' << device.index << "] " << device.name << '\n';
            return 0;
        }

        if (pool.empty() || username.empty()) {
            print_help();
            return 2;
        }

        pepepow::stratum::Config config;
        config.primary = pepepow::stratum::parse_endpoint(pool);
        if (fallback.has_value()) config.fallback = pepepow::stratum::parse_endpoint(*fallback);
        config.username = username;
        config.password = password;
        config.agent = "PepePowMiner/0.1.1-rc1";

        pepepow::stratum::Client client(std::move(config));
        MiningWorker worker(backend, client);
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
