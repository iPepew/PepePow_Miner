#include "pepepow/stratum/client.hpp"
#include <nlohmann/json.hpp>

#include <chrono>
#include <condition_variable>
#include <exception>
#include <iostream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
int main() {
    std::cout << "SKIP: reconnect socket replay is covered on Linux\n";
    return 0;
}
#else
#include "pepepow/stratum/evidence_file.hpp"
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace {
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct Fd {
    int value;
    explicit Fd(int fd) : value(fd) { require(fd >= 0, "socket/accept failed"); }
    ~Fd() { ::close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};

int accept_peer(int listener) {
    pollfd event{listener, POLLIN, 0};
    require(::poll(&event, 1, 3000) == 1, "accept deadline exceeded");
    return ::accept(listener, nullptr, nullptr);
}

void set_timeout(int fd) {
    timeval timeout{3, 0};
    require(::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0,
            "receive timeout setup failed");
    require(::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0,
            "send timeout setup failed");
}

void send_json(int fd, const json& message) {
    const auto line = message.dump() + "\n";
    std::size_t sent = 0;
    while (sent < line.size()) {
        const auto count = ::send(fd, line.data() + sent, line.size() - sent, MSG_NOSIGNAL);
        require(count > 0, "mock send failed");
        sent += static_cast<std::size_t>(count);
    }
}

json read_json(int fd, std::string& buffer) {
    char chunk[2048];
    for (;;) {
        const auto end = buffer.find('\n');
        if (end != std::string::npos) {
            auto line = buffer.substr(0, end);
            buffer.erase(0, end + 1U);
            return json::parse(line);
        }
        const auto count = ::recv(fd, chunk, sizeof(chunk), 0);
        require(count > 0, "mock receive failed");
        buffer.append(chunk, static_cast<std::size_t>(count));
        require(buffer.size() <= 16384U, "mock message too large");
    }
}

json notify(const std::string& id, bool clean) {
    return {{"id", nullptr}, {"method", "mining.notify"},
            {"params", json::array({id, std::string(64, '0'), "01000000", "",
             json::array(), "20000000", "1d00ffff", "5f5e1000", clean})}};
}

void handshake(int fd, std::string& buffer) {
    const auto subscribe = read_json(fd, buffer);
    const auto authorize = read_json(fd, buffer);
    require(subscribe.at("method") == "mining.subscribe", "missing subscribe");
    require(authorize.at("method") == "mining.authorize", "missing authorize");
    send_json(fd, {{"id", subscribe.at("id")},
                  {"result", json::array({json::array(), "abcd", 4})}, {"error", nullptr}});
    send_json(fd, {{"id", authorize.at("id")}, {"result", true}, {"error", nullptr}});
}

int submit_id(int fd, std::string& buffer, const std::string& job) {
    const auto message = read_json(fd, buffer);
    require(message.at("method") == "mining.submit", "missing submit");
    require(message.at("params").at(1) == job, "wrong submitted job");
    return message.at("id").get<int>();
}

int replay(const std::string& evidence_mode, const std::string& evidence_path) {
    Fd listener(::socket(AF_INET, SOCK_STREAM, 0));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    require(::bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
            "bind failed");
    require(::listen(listener.value, 2) == 0, "listen failed");
    socklen_t size = sizeof(address);
    require(::getsockname(listener.value, reinterpret_cast<sockaddr*>(&address), &size) == 0,
            "getsockname failed");

    std::mutex mutex;
    std::condition_variable cv;
    std::vector<std::string> jobs;
    std::vector<std::string> logs;
    std::vector<json> evidence;
    unsigned sink_calls = 0;
    bool finish = false;
    std::exception_ptr server_error;
    Clock::time_point old_reject_sent{}, second_clean_sent{};

    pepepow::stratum::Config config;
    config.primary = {"127.0.0.1", ntohs(address.sin_port), false};
    config.username = "synthetic.worker";
    config.password = "synthetic-only";
    config.reconnect_seconds = 0; // Deliberately stay inside the attribution window.
    std::unique_ptr<pepepow::stratum::EvidenceFile> evidence_file;
    if (!evidence_path.empty()) evidence_file = std::make_unique<pepepow::stratum::EvidenceFile>(evidence_path);
    pepepow::stratum::Client client(std::move(config));
    if (!evidence_mode.empty()) client.set_evidence_handler([&](const std::string& line) {
        ++sink_calls;
        if (evidence_mode == "--evidence-failure") throw std::runtime_error("synthetic sink failure");
        if (evidence_file) evidence_file->write(line);
        require(!line.empty() && line.back() == '\n', "evidence must be JSONL");
        require(line.find("synthetic") == std::string::npos, "credential leaked to evidence");
        require(line.find("old-job") == std::string::npos, "raw job leaked to evidence");
        require(line.find("private-error-text") == std::string::npos, "pool text leaked to evidence");
        evidence.push_back(json::parse(line));
    });
    client.set_log_handler([&](const std::string& line) {
        std::lock_guard lock(mutex);
        logs.push_back(line);
    });
    client.set_job_handler([&](const pepepow::stratum::Job& job) {
        { std::lock_guard lock(mutex); jobs.push_back(job.job_id); }
        cv.notify_all();
    });

    std::thread server([&] {
        try {
            int old_id = -1;
            {
                Fd peer(accept_peer(listener.value));
                set_timeout(peer.value);
                std::string buffer;
                handshake(peer.value, buffer);
                send_json(peer.value, notify("old-job", false));
                old_id = submit_id(peer.value, buffer, "old-job");
                old_reject_sent = Clock::now();
                send_json(peer.value, {{"id", old_id}, {"result", false}, {"error", nullptr}});
                // TCP preserves order: the client consumes the reject before EOF.
                ::shutdown(peer.value, SHUT_WR);
            }
            Fd peer(accept_peer(listener.value));
            set_timeout(peer.value);
            std::string buffer;
            handshake(peer.value, buffer);
            second_clean_sent = Clock::now();
            send_json(peer.value, notify("new-job", true));
            const auto new_id = submit_id(peer.value, buffer, "new-job");
            require(new_id != old_id, "submit IDs unexpectedly reused");
            // A late/duplicate response from the previous connection is not
            // a second rejection. An explicit new rejection near clean stays
            // ordinary, even though the old null rejection was very recent.
            send_json(peer.value, {{"id", old_id}, {"result", false}, {"error", nullptr}});
            if (evidence_mode == "--evidence-invalid") {
                // A 64-bit ID must not narrow to the pending 32-bit ID.
                send_json(peer.value, {{"id", (std::uint64_t{1} << 32U) + static_cast<unsigned>(new_id)},
                                      {"result", true}, {"error", nullptr}});
                send_json(peer.value, {{"id", "private-error-text"}, {"result", true}, {"error", nullptr}});
                send_json(peer.value, {{"id", std::numeric_limits<std::uint64_t>::max()}, {"result", true}, {"error", nullptr}});
                send_json(peer.value, {{"id", -1}, {"result", true}, {"error", nullptr}});
                send_json(peer.value, {{"id", static_cast<double>(new_id)}, {"result", true}, {"error", nullptr}});
            }
            send_json(peer.value, {{"id", new_id}, {"result", false},
                                  {"error", json::array({23, "low difficulty share", nullptr})}});
            // Completed IDs must also be ignored within the current connection:
            // neither a duplicate reject nor a contradictory success is new work.
            send_json(peer.value, {{"id", new_id}, {"result", false}, {"error", nullptr}});
            send_json(peer.value, {{"id", new_id}, {"result", true}, {"error", nullptr}});
            send_json(peer.value, {{"id", 9999}, {"result", "synthetic-only"},
                                  {"error", json::array({99, "private-error-text", "synthetic.worker"})}});
            if (evidence_mode == "--evidence-invalid") send_json(peer.value, json::array({"private-error-text"}));
            send_json(peer.value, notify("newer-job", true));
            const auto fresh_id = submit_id(peer.value, buffer, "newer-job");
            send_json(peer.value, {{"id", fresh_id}, {"result", true}, {"error", nullptr}});
            send_json(peer.value, {{"id", fresh_id}, {"result", true}, {"error", nullptr}});
            send_json(peer.value, {{"id", fresh_id}, {"result", false}, {"error", nullptr}});
            // A job callback is a receive-order barrier, eliminating stats polling.
            send_json(peer.value, notify("drained", false));
            std::unique_lock lock(mutex);
            cv.wait_for(lock, 3s, [&] { return finish; });
        } catch (...) {
            { std::lock_guard lock(mutex); server_error = std::current_exception(); }
            cv.notify_all();
        }
    });
    std::thread receiver([&] { client.run(); });
    std::exception_ptr client_error;
    pepepow::stratum::Stats stats;
    try {
        auto wait_job = [&](const std::string& id) {
            std::unique_lock lock(mutex);
            require(cv.wait_for(lock, 3s, [&] {
                return server_error || (!jobs.empty() && jobs.back() == id);
            }), "job callback deadline exceeded");
            if (server_error) std::rethrow_exception(server_error);
        };
        wait_job("old-job");
        require(client.submit({"old-job", "00000001", "5f5e1000", "00000001"}), "old submit failed");
        wait_job("new-job");
        require(client.submit({"new-job", "00000002", "5f5e1000", "00000002"}), "new submit failed");
        wait_job("newer-job");
        require(client.submit({"newer-job", "00000003", "5f5e1000", "00000003"}), "fresh submit failed");
        wait_job("drained");
        stats = client.stats();
    } catch (...) { client_error = std::current_exception(); }

    // The mock keeps the second socket open until stop, so shutdown cannot
    // accidentally introduce a second reconnect during the measurement.
    client.stop();
    receiver.join();
    { std::lock_guard lock(mutex); finish = true; }
    cv.notify_all();
    server.join();
    client.finish_evidence();
    if (evidence_file) evidence_file->close();
    if (server_error) std::rethrow_exception(server_error);
    if (client_error) std::rethrow_exception(client_error);

    const auto gap = std::chrono::duration_cast<std::chrono::milliseconds>(
        second_clean_sent - old_reject_sent).count();
    std::cout << "reconnect replay accepted=" << stats.accepted
              << " rejected=" << stats.rejected
              << " clean_job_stale=" << stats.clean_job_stale
              << " reconnects=" << stats.reconnects
              << " reject_to_clean_ms=" << gap << '\n';
    require(gap >= 0 && gap < 2000, "replay missed the two-second regression window");
    require(stats.accepted == 1, "accepted count mismatch");
    require(stats.rejected == 2, "inclusive reject count mismatch (duplicate counted?)");
    require(stats.reconnects == 1, "reconnect count mismatch");
    require(stats.clean_job_stale == 0, "old-connection rejection leaked into new clean job");
    if (evidence_mode == "--evidence-failure") {
        require(sink_calls == 1, "failed evidence sink was retried");
        require(client.stats().evidence_errors == 1, "sink failure not exposed");
    } else if (evidence_mode == "--evidence" || evidence_mode == "--evidence-invalid") {
        require(client.stats().evidence_errors == 0, "evidence sink unexpectedly failed");
        require(evidence.front().at("event") == "stream_start", "missing stream start");
        require(evidence.back().at("event") == "stream_end", "missing stream end");
        std::uint64_t seq = 0, previous_us = 0;
        unsigned matched = 0, unmatched = 0, connections = 0, closes = 0, submits = 0, invalid = 0;
        for (const auto& event : evidence) {
            require(event.at("schema") == "pepew-stratum-evidence-v1", "schema mismatch");
            require(event.at("seq").get<std::uint64_t>() == ++seq, "event sequence gap");
            const auto us = event.at("monotonic_us").get<std::uint64_t>();
            require(us >= previous_us, "non-monotonic evidence time");
            previous_us = us;
            const auto epoch = event.at("connection_epoch").get<unsigned>();
            if (event.at("event") == "connection_open") {
                require(epoch == ++connections, "connection epoch mismatch");
            } else if (event.at("event") == "connection_close") ++closes;
            else if (event.at("event") == "invalid_message") ++invalid;
            else if (event.at("event") == "submit_attempt") ++submits;
            else if (event.at("event") == "response") {
                if (event.at("matched") == true) {
                    ++matched;
                    require(event.at("clean_ref") == 0, "unexpected invalidation reference");
                    require(event.at("job_ref").get<std::string>().size() == 64, "bad job digest");
                    require(epoch == (matched == 1 ? 1U : 2U), "response crossed epochs");
                } else ++unmatched;
                if (event.at("submit_id") == 9999) {
                    require(event.at("result_type") == "string", "result shape lost");
                    require(event.at("result_bool").is_null(), "untrusted result copied");
                    require(event.at("error_code") == 99, "safe error code lost");
                }
            }
            require(event.at("event") != "temporal_attribution", "cross-epoch attribution");
        }
        require(connections == 2 && closes == 2 && submits == 3, "lifecycle count mismatch");
        require(matched == 3 && unmatched == 6, "response evidence count mismatch");
        require(invalid == (evidence_mode == "--evidence-invalid" ? 6U : 0U), "invalid message missing");
        require(evidence.back().at("accepted") == 1 &&
                evidence.back().at("rejected_inclusive") == 2, "final evidence counters mismatch");
        for (const auto& event : evidence) std::cout << event.dump() << '\n';
    } else require(sink_calls == 0, "evidence not opt-in");
    for (const auto& line : logs) {
        require(line.find("Share stale") == std::string::npos, "unexpected stale attribution log");
    }
    std::cout << "PASS: reconnect isolates rejection history; cross-connection and same-connection duplicates/contradictions ignored; explicit reject preserved\n";
    return 0;
}
} // namespace

int main(int argc, char** argv) {
    try { return replay(argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : ""); }
    catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
#endif
