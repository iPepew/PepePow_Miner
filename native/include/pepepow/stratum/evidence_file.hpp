#pragma once

// The production console application already targets POSIX. Keep the file
// sink outside the portable Stratum Client; socket tests can inject a sink.
#include <cerrno>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace pepepow::stratum {
class EvidenceFile {
public:
    explicit EvidenceFile(const std::string& path) {
        fd_ = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd_ < 0) throw std::runtime_error("cannot create Stratum evidence file (path must be new)");
    }
    ~EvidenceFile() { if (fd_ >= 0) ::close(fd_); }
    EvidenceFile(const EvidenceFile&) = delete;
    EvidenceFile& operator=(const EvidenceFile&) = delete;

    // Client serializes callers. Regular local files only; synchronous writes
    // can perturb timings. No claim of power-loss durability is made.
    void write(const std::string& line) {
        if (fd_ < 0) throw std::runtime_error("Stratum evidence file is closed");
        std::size_t sent = 0;
        while (sent < line.size()) {
            const auto count = ::write(fd_, line.data() + sent, line.size() - sent);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) throw std::runtime_error("Stratum evidence write failed");
            sent += static_cast<std::size_t>(count);
        }
    }

    void close() {
        const auto fd = fd_;
        fd_ = -1;
        if (fd >= 0 && ::close(fd) != 0) throw std::runtime_error("Stratum evidence close failed");
    }
private:
    int fd_{-1};
};
} // namespace pepepow::stratum
