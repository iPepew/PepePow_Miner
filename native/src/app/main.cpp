#include "pepepow/core/backend.hpp"
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#include "pepepow/version.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/cuda/header80_backend.hpp"
#endif

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
#include <thread>

namespace {
pepepow::stratum::Client* active_client = nullptr;

std::string now_iso() {
    const auto now = std::chrono::system_clock::now();
    const auto time = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &time);
#else
    localtime_r(&time, &tm);
#endif
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S");
    return out.str();
}

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
        std::cout << line << '\n';
        if (file_) { file_ << line << '\n'; file_.flush(); }
    }

    [[nodiscard]] const std::string& path() const noexcept { return path_; }

private:
    std::string path_;
    std::ofstream file_;
    std::mutex mutex_;
};

void signal_handler(int) { if (active_client != nullptr) active_client->stop(); }

std::string build_identity() {
    return std::string("PepePow Debug Edition ") + PEPEPOW_VERSION +
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
              << "      --pepepow           Select PEPEPOW/HooHash V110 mode\n"
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

struct WorkItem { pepepow::stratum::Job stratum_job; std::string extranonce2; std::uint64_t generation{0}; };

class MiningWorker {
public:
    MiningWorker(pepepow::MiningBackend& backend, pepepow::stratum::Client& client,
                 DiagnosticLog& log, bool diagnostic)
        : backend_(backend), client_(client), log_(log), diagnostic_(diagnostic),
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
                const double normalized = item.stratum_job.difficulty / pepepow::mining::kStratumDifficultyWireScale;
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
                           " target_be=" + hex_of(target));

                if (diagnostic_) {
                    auto initial = mining_job;
                    initial.nonce = 0;
                    log_.write("JOB_HEADER nonce=00000000 header80=" + hex_of(pepepow::build_header80(initial)) +
                               " prevhash_wire=" + item.stratum_job.prevhash +
                               " coinb1=" + item.stratum_job.coinb1 +
                               " coinb2=" + item.stratum_job.coinb2 +
                               " merkle_count=" + std::to_string(item.stratum_job.merkle_branch.size()));
                }

                while (!stopped_.load() && item.generation == generation_.load() && nonce <= 0xffffffffULL) {
                    const std::uint64_t remaining = 0x100000000ULL - nonce;
                    const std::uint64_t count = remaining < chunk_size ? remaining : chunk_size;
                    const auto candidate = backend_.search(mining_job, pepepow::SearchRange{nonce, count}, target);
                    if (candidate.has_value()) {
                        auto validation_job = mining_job;
                        validation_job.nonce = candidate->nonce;
                        const auto header = pepepow::build_header80(validation_job);
                        const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);
                        const bool gpu_cpu_match = cpu_hash == candidate->hash;
                        const bool target_ok = pepepow::mining::hash_meets_target_be(cpu_hash, target);
                        const std::string nonce_wire = pepepow::stratum::encode_u32_le_hex(candidate->nonce);

                        log_.write("CANDIDATE job=" + item.stratum_job.job_id +
                                   " nonce_u32=" + std::to_string(candidate->nonce) +
                                   " nonce_wire=" + nonce_wire +
                                   " xnonce2=" + item.extranonce2 +
                                   " gpu_hash=" + hex_of(candidate->hash) +
                                   " cpu_hash=" + hex_of(cpu_hash) +
                                   " match=" + std::to_string(gpu_cpu_match) +
                                   " target_ok=" + std::to_string(target_ok));

                        if (diagnostic_) {
                            log_.write("SHARE_TRACE job=" + item.stratum_job.job_id +
                                       " header80=" + hex_of(header) +
                                       " hash_be=" + hex_of(cpu_hash) +
                                       " target_be=" + hex_of(target) +
                                       " ntime=" + item.stratum_job.ntime +
                                       " nonce_wire=" + nonce_wire +
                                       " xnonce2=" + item.extranonce2);
                        }

                        if (gpu_cpu_match && target_ok && item.generation == generation_.load()) {
                            pepepow::stratum::Share share{item.stratum_job.job_id, item.extranonce2,
                                                         item.stratum_job.ntime, nonce_wire};
                            const bool sent = client_.submit(share);
                            log_.write(std::string("SUBMIT job=") + share.job_id +
                                       " sent=" + std::to_string(sent) +
                                       " params=[user," + share.job_id + ',' + share.extranonce2 + ',' +
                                       share.ntime + ',' + share.nonce + "]");
                        }
                    }
                    nonce += count;
                }
            } catch (const std::exception& error) {
                log_.write(std::string("WORKER_ERROR ") + error.what());
            }
        }
    }

    pepepow::MiningBackend& backend_;
    pepepow::stratum::Client& client_;
    DiagnosticLog& log_;
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
            std::getenv("PEPEPOW_DIAGNOSTIC_LOG") : "/tmp/pepepow-debug-edition.log";

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
            for (const auto& device : devices) std::cout << '[' << device.index << "] " << device.name << " sm_" << device.compute_major << device.compute_minor << '\n';
            return 0;
        }
        if (devices.empty()) throw std::runtime_error("no mining device available");
        if (pool.empty() || username.empty()) { print_help(); return 2; }

        DiagnosticLog log(diagnostic_log);
        log.write("BUILD_ID " + build_identity() + " diagnostic=" + std::to_string(diagnostic) + " log=" + log.path());

        pepepow::stratum::Config config;
        config.primary = pepepow::stratum::parse_endpoint(pool);
        if (fallback.has_value()) config.fallback = pepepow::stratum::parse_endpoint(*fallback);
        config.username = username;
        config.password = password;
        config.agent = std::string("PepePowDebugEdition/") + PEPEPOW_VERSION;

        pepepow::stratum::Client client(std::move(config));
        client.set_log_handler([&log](const std::string& line) { log.write("STRATUM " + line); });
        MiningWorker worker(*backend, client, log, diagnostic);
        active_client = &client;
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);
        client.set_job_handler([&worker](const pepepow::stratum::Job& job) { worker.set_job(job); });
        client.run();
        worker.stop();
        const auto stats = client.stats();
        log.write("FINAL_STATS accepted=" + std::to_string(stats.accepted) +
                  " rejected=" + std::to_string(stats.rejected) +
                  " reconnects=" + std::to_string(stats.reconnects));
        active_client = nullptr;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Fatal: " << error.what() << '\n';
        return 1;
    }
}
