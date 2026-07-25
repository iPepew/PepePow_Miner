#pragma once

#include "pepepow/core/types.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace pepepow::stratum {

struct Endpoint {
    std::string host;
    std::uint16_t port{0};
    bool tls{false};
};

struct Config {
    Endpoint primary;
    std::optional<Endpoint> fallback;
    std::string username;
    std::string password{"x"};
    std::string agent{"PepePowMiner/0.2.0-dev"};
    unsigned reconnect_seconds{5};
};

struct Job {
    std::string job_id;
    std::string prevhash;
    std::string coinb1;
    std::string coinb2;
    std::vector<std::string> merkle_branch;
    std::string version;
    std::string nbits;
    std::string ntime;
    bool clean_jobs{false};
    std::string extranonce1;
    std::size_t extranonce2_size{4};
    double difficulty{1.0};
};

struct Share {
    std::string job_id;
    std::string extranonce2;
    std::string ntime;
    std::string nonce;
};

struct Stats {
    std::uint64_t accepted{0};
    std::uint64_t rejected{0};
    std::uint64_t reconnects{0};
};

class Client {
public:
    using JobHandler = std::function<void(const Job&)>;
    using LogHandler = std::function<void(const std::string&)>;

    explicit Client(Config config);
    ~Client();
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    void set_job_handler(JobHandler handler);
    void set_log_handler(LogHandler handler);
    void run();
    void stop();
    bool submit(const Share& share);
    [[nodiscard]] Stats stats() const noexcept;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] Endpoint parse_endpoint(const std::string& url);
[[nodiscard]] MiningJob build_mining_job(const Job& job, const std::string& extranonce2);
[[nodiscard]] std::string encode_u32_le_hex(std::uint32_t value);

} // namespace pepepow::stratum
