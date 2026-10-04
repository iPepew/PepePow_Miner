#include "pepepow/stratum/client.hpp"

#include <nlohmann/json.hpp>

#include <atomic>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32

int main() {
    std::cout << "SKIP: loopback Stratum replay is covered on Linux CI\n";
    return 0;
}

#else

#include "pepepow/stratum/evidence_file.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace {
using json = nlohmann::json;
using namespace std::chrono_literals;

struct Fd {
    int value{-1};
    ~Fd() { if (value >= 0) ::close(value); }
    Fd() = default;
    explicit Fd(int fd) : value(fd) {}
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};

void set_timeout(int fd) {
    timeval timeout{};
    timeout.tv_sec = 5;
    if (::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) {
        throw std::runtime_error("setsockopt timeout failed");
    }
}

void send_json(int fd, const json& value) {
    const std::string line = value.dump() + "\n";
    std::size_t sent = 0;
    while (sent < line.size()) {
        const auto count = ::send(fd, line.data() + sent, line.size() - sent, MSG_NOSIGNAL);
        if (count <= 0) throw std::runtime_error("mock pool send failed");
        sent += static_cast<std::size_t>(count);
    }
}

json read_json(int fd, std::string& buffer) {
    char chunk[2048];
    for (;;) {
        const auto newline = buffer.find('\n');
        if (newline != std::string::npos) {
            const auto line = buffer.substr(0, newline);
            buffer.erase(0, newline + 1U);
            return json::parse(line);
        }
        const auto count = ::recv(fd, chunk, sizeof(chunk), 0);
        if (count <= 0) throw std::runtime_error("mock pool receive failed");
        buffer.append(chunk, static_cast<std::size_t>(count));
    }
}

json notify(std::string job_id, bool clean) {
    return {
        {"id", nullptr},
        {"method", "mining.notify"},
        {"params", json::array({
            std::move(job_id),
            std::string(64, '0'),
            "01000000",
            "",
            json::array(),
            "20000000",
            "1d00ffff",
            "5f5e1000",
            clean
        })}
    };
}

bool wait_for(const std::function<bool()>& predicate,
              std::condition_variable& cv, std::mutex& mutex) {
    std::unique_lock lock(mutex);
    return cv.wait_for(lock, 5s, predicate);
}
} // namespace

int main(int argc, char** argv) {
    Fd listener(::socket(AF_INET, SOCK_STREAM, 0));
    if (listener.value < 0) throw std::runtime_error("socket failed");

    int reuse = 1;
    ::setsockopt(listener.value, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (::bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        ::listen(listener.value, 1) != 0) {
        throw std::runtime_error("bind/listen failed");
    }
    socklen_t address_size = sizeof(address);
    if (::getsockname(listener.value, reinterpret_cast<sockaddr*>(&address), &address_size) != 0) {
        throw std::runtime_error("getsockname failed");
    }
    const auto port = ntohs(address.sin_port);

    std::mutex jobs_mutex;
    std::condition_variable jobs_cv;
    std::vector<std::string> jobs;
    std::mutex finish_mutex;
    std::condition_variable finish_cv;
    bool finish = false;
    std::exception_ptr server_error;

    std::thread server([&] {
        try {
            Fd peer(::accept(listener.value, nullptr, nullptr));
            if (peer.value < 0) throw std::runtime_error("accept failed");
            set_timeout(peer.value);
            std::string buffer;

            const auto subscribe = read_json(peer.value, buffer);
            const auto authorize = read_json(peer.value, buffer);
            assert(subscribe.at("id") == 1);
            assert(subscribe.at("method") == "mining.subscribe");
            assert(authorize.at("id") == 2);
            assert(authorize.at("method") == "mining.authorize");

            send_json(peer.value, {
                {"id", 1},
                {"result", json::array({json::array(), "abcd", 4})},
                {"error", nullptr}
            });
            send_json(peer.value, {{"id", 2}, {"result", true}, {"error", nullptr}});
            send_json(peer.value, {
                {"id", nullptr},
                {"method", "mining.set_difficulty"},
                {"params", json::array({98.304})}
            });
            send_json(peer.value, notify("old-job", false));

            std::vector<int> old_ids;
            for (int index = 0; index < 4; ++index) {
                const auto submit = read_json(peer.value, buffer);
                assert(submit.at("method") == "mining.submit");
                assert(submit.at("params").at(1) == "old-job");
                old_ids.push_back(submit.at("id").get<int>());
            }

            // This pool rejects a batch just before delivering the clean-job
            // notification. The response is still attributable to the
            // transition when the clean notification follows immediately.
            send_json(peer.value, {{"id", old_ids[0]}, {"result", false}, {"error", nullptr}});
            send_json(peer.value, notify("new-job", true));
            send_json(peer.value, {{"id", old_ids[1]}, {"result", true}, {"error", nullptr}});
            send_json(peer.value, {{"id", old_ids[2]}, {"result", false}, {"error", nullptr}});
            send_json(peer.value, {
                {"id", old_ids[3]},
                {"result", false},
                {"error", json::array({23, "low difficulty share", nullptr})}
            });

            const auto fresh_submit = read_json(peer.value, buffer);
            assert(fresh_submit.at("method") == "mining.submit");
            assert(fresh_submit.at("params").at(1) == "new-job");
            send_json(peer.value, {
                {"id", fresh_submit.at("id")},
                {"result", true},
                {"error", nullptr}
            });

            std::unique_lock lock(finish_mutex);
            finish_cv.wait_for(lock, 5s, [&] { return finish; });
        } catch (...) {
            server_error = std::current_exception();
        }
    });

    pepepow::stratum::Config config;
    config.primary = {"127.0.0.1", port, false};
    config.username = "test.worker";
    config.password = "x";
    config.agent = "PepeW/socket-replay";
    config.reconnect_seconds = 1;

    std::unique_ptr<pepepow::stratum::EvidenceFile> evidence_file;
    if (argc > 1) evidence_file = std::make_unique<pepepow::stratum::EvidenceFile>(argv[1]);
    pepepow::stratum::Client client(std::move(config));
    std::mutex logs_mutex;
    std::vector<std::string> logs;
    std::vector<json> evidence;
    client.set_evidence_handler([&](const std::string& line) {
        if (evidence_file) evidence_file->write(line);
        evidence.push_back(json::parse(line));
    });
    client.set_log_handler([&](const std::string& message) {
        std::lock_guard lock(logs_mutex);
        logs.push_back(message);
    });
    client.set_job_handler([&](const pepepow::stratum::Job& job) {
        {
            std::lock_guard lock(jobs_mutex);
            jobs.push_back(job.job_id);
        }
        jobs_cv.notify_all();
    });

    std::thread client_thread([&] { client.run(); });

    assert(wait_for([&] { return !jobs.empty(); }, jobs_cv, jobs_mutex));
    for (int index = 0; index < 4; ++index) {
        assert(client.submit({"old-job", "00000001", "5f5e1000",
                              "0000000" + std::to_string(index + 1)}));
    }

    assert(wait_for([&] { return jobs.size() >= 2U; }, jobs_cv, jobs_mutex));
    assert(client.submit({"new-job", "00000002", "5f5e1000", "00000004"}));

    const auto stats_deadline = std::chrono::steady_clock::now() + 5s;
    pepepow::stratum::Stats stats;
    do {
        stats = client.stats();
        if (stats.accepted == 2U && stats.rejected == 3U &&
            stats.clean_job_stale == 2U) {
            break;
        }
        std::this_thread::sleep_for(10ms);
    } while (std::chrono::steady_clock::now() < stats_deadline);

    client.stop();
    if (client_thread.joinable()) client_thread.join();
    {
        std::lock_guard lock(finish_mutex);
        finish = true;
    }
    finish_cv.notify_all();
    if (server.joinable()) server.join();
    client.finish_evidence();
    if (evidence_file) evidence_file->close();
    if (server_error) std::rethrow_exception(server_error);

    assert(jobs.size() == 2U);
    assert(jobs[0] == "old-job");
    assert(jobs[1] == "new-job");
    assert(stats.accepted == 2U);
    assert(stats.rejected == 3U);
    assert(stats.clean_job_stale == 2U);
    assert(stats.reconnects == 0U);

    bool saw_stale = false;
    bool saw_pre_notify_stale = false;
    bool saw_explicit_reject = false;
    {
        std::lock_guard lock(logs_mutex);
        for (const auto& message : logs) {
            saw_stale = saw_stale ||
                message.find("Share stale after clean job: job=old-job") != std::string::npos;
            saw_pre_notify_stale = saw_pre_notify_stale ||
                message.find("Share stale around clean job: job=old-job") != std::string::npos;
            saw_explicit_reject = saw_explicit_reject ||
                message.find("Share rejected: job=old-job reason=low difficulty share") !=
                    std::string::npos;
        }
    }
    assert(saw_stale);
    assert(saw_pre_notify_stale);
    assert(saw_explicit_reject);

    assert(client.stats().evidence_errors == 0);
    assert(evidence.front().at("event") == "stream_start");
    assert(evidence.back().at("event") == "stream_end");
    std::uint64_t clean_ref = 0, rejected_ref = 0, seq = 0, previous_us = 0;
    unsigned pre = 0, post = 0, matched = 0;
    for (const auto& event : evidence) {
        assert(event.at("seq").get<std::uint64_t>() == ++seq);
        const auto us = event.at("monotonic_us").get<std::uint64_t>();
        assert(us >= previous_us);
        previous_us = us;
        if (event.at("event") == "job" && event.at("clean") == true) clean_ref = seq;
        if (event.at("event") == "response" && event.at("matched") == true) {
            ++matched;
            if (matched == 1) {
                rejected_ref = seq;
                assert(event.at("classification") == "rejected");
                assert(event.at("clean_ref") == 0);
            } else if (matched <= 4) {
                assert(clean_ref != 0 && event.at("clean_ref") == clean_ref);
                if (matched == 2) assert(event.at("classification") == "accepted");
                if (matched == 3) {
                    assert(event.at("classification") == "suspected_post_notify_stale");
                    ++post;
                }
                if (matched == 4) {
                    assert(event.at("classification") == "rejected");
                    assert(event.at("error_code") == 23);
                }
            } else assert(event.at("clean_ref") == 0);
        }
        if (event.at("event") == "temporal_attribution") {
            ++pre;
            assert(event.at("classification") == "suspected_pre_notify_stale");
            assert(event.at("response_ref") == rejected_ref);
            assert(event.at("clean_ref") == clean_ref);
            assert(rejected_ref < clean_ref && clean_ref < seq);
        }
    }
    assert(pre == 1 && post == 1 && matched == 5);
    assert(evidence.back().at("accepted") == 2);
    assert(evidence.back().at("rejected_inclusive") == 3);
    assert(evidence.back().at("temporal_stale") == 2);

    std::cout << "PASS: socket clean-job replay accepted=2 rejected=3 clean_job_stale=2\n";
    return 0;
}

#endif
