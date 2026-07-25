#include "pepepow/core/backend.hpp"
#include "pepepow/stratum/client.hpp"

#include <csignal>
#include <exception>
#include <iostream>
#include <optional>
#include <string>

namespace {
pepepow::stratum::Client* active_client = nullptr;

void signal_handler(int) {
    if (active_client != nullptr) active_client->stop();
}

void print_help() {
    std::cout
        << "PepePowMiner v0.2.0-dev\n"
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
}

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

        pepepow::stratum::Client client(std::move(config));
        active_client = &client;
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);

        client.set_job_handler([](const pepepow::stratum::Job& job) {
            const std::string extranonce2(job.extranonce2_size * 2U, '0');
            const auto mining_job = pepepow::stratum::build_mining_job(job, extranonce2);
            std::cout << "Prepared job " << mining_job.job_id
                      << " ntime=" << job.ntime
                      << " difficulty=" << job.difficulty << '\n';
#ifdef PEPEPOW_HAS_CUDA
            std::cout << "CUDA worker integration pending for this job\n";
#endif
        });

        client.run();
        active_client = nullptr;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Fatal: " << error.what() << '\n';
        return 1;
    }
}
