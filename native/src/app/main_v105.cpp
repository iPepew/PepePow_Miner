#include "pepepow/core/backend.hpp"
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"
#include "pepepow/version.hpp"
#ifdef PEPEPOW_HAS_CUDA
#include "pepepow/cuda/header80_backend.hpp"
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
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
#include <regex>
#include <sstream>
#include <stdexcept>
#include <streambuf>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>

#define main pepepow_legacy_main
#include "main.cpp"
#undef main

namespace {

std::string ascii_plain(std::string_view input) {
    std::string output;
    output.reserve(input.size());
    bool escape = false;
    for (unsigned char byte : input) {
        if (escape) {
            if (byte >= 0x40U && byte <= 0x7eU) escape = false;
            continue;
        }
        if (byte == 0x1bU) {
            escape = true;
            continue;
        }
        if (byte == '\r') continue;
        if (byte == '\t' || (byte >= 0x20U && byte <= 0x7eU)) {
            output.push_back(static_cast<char>(byte));
        }
    }
    return output;
}

std::string trim(std::string value) {
    const auto first = value.find_first_not_of(' ');
    if (first == std::string::npos) return {};
    const auto last = value.find_last_not_of(' ');
    return value.substr(first, last - first + 1U);
}

std::string professional_line(std::string_view raw) {
    const std::string line = trim(ascii_plain(raw));
    if (line.empty()) return {};

    if (line.find("PepeW Miner") != std::string::npos) {
        return "PepeW Miner 1.0.5";
    }
    if (line.find("PepeW") != std::string::npos &&
        line.find("Version") == std::string::npos) {
        return {};
    }
    if (line.find("====") != std::string::npos) return {};

    if (line.find("HOOHASH") != std::string::npos &&
        line.find("Consensus") != std::string::npos) {
        return "[HOOHASH] Consensus V110 verified";
    }
    if (line.find("POOL") != std::string::npos &&
        line.find("Connected") != std::string::npos) {
        return "[POOL] Connected";
    }
    if (line.find("POOL") != std::string::npos &&
        line.find("Subscribed") != std::string::npos) {
        return "[POOL] Subscribed";
    }
    if (line.find("READY") != std::string::npos &&
        line.find("authorization") != std::string::npos) {
        return "[POOL] Authorized";
    }
    if (line.find("DIFF") != std::string::npos) {
        const auto pos = line.find("DIFF");
        return "[DIFF]" + line.substr(pos + 4U);
    }
    if (line.find("ACCEPTED") != std::string::npos) {
        const auto pos = line.find("ACCEPTED");
        return "[ACCEPTED] " + trim(line.substr(pos + 8U));
    }
    if (line.find("REJECTED") != std::string::npos) {
        const auto pos = line.find("REJECTED");
        return "[REJECTED] " + trim(line.substr(pos + 8U));
    }
    if (line.find("JOB") != std::string::npos) {
        const auto pos = line.find("JOB");
        return "[JOB] " + trim(line.substr(pos + 3U));
    }
    if (line.find("ERROR") != std::string::npos ||
        line.find("FATAL") != std::string::npos) {
        return "[ERROR] " + line;
    }

    static const std::regex mining_pattern(
        R"(([0-9]+(?:\.[0-9]+)?)\s+MH/s.*?A\s+([0-9]+).*?R\s+([0-9]+).*?([0-9]{2}:[0-9]{2}:[0-9]{2}))");
    std::smatch match;
    if (line.find("Mining") != std::string::npos &&
        std::regex_search(line, match, mining_pattern)) {
        return "[MINING] " + match[1].str() + " MH/s | A " + match[2].str() +
               " | R " + match[3].str() + " | UP " + match[4].str();
    }

    return line;
}

class AsciiLineBuffer final : public std::streambuf {
public:
    explicit AsciiLineBuffer(std::streambuf* target) : target_(target) {}
    ~AsciiLineBuffer() override { sync(); }

protected:
    int overflow(int ch) override {
        if (ch == traits_type::eof()) return traits_type::not_eof(ch);
        const char value = static_cast<char>(ch);
        if (value == '\n') flush_line();
        else line_.push_back(value);
        return ch;
    }

    std::streamsize xsputn(const char* data, std::streamsize count) override {
        for (std::streamsize i = 0; i < count; ++i) overflow(data[i]);
        return count;
    }

    int sync() override {
        if (!line_.empty()) flush_line();
        return target_->pubsync();
    }

private:
    void flush_line() {
        const std::string output = professional_line(line_);
        if (!output.empty()) {
            target_->sputn(output.data(), static_cast<std::streamsize>(output.size()));
            target_->sputc('\n');
        }
        line_.clear();
    }

    std::streambuf* target_;
    std::string line_;
};

} // namespace

int main(int argc, char** argv) {
    AsciiLineBuffer stdout_filter(std::cout.rdbuf());
    AsciiLineBuffer stderr_filter(std::cerr.rdbuf());
    auto* old_stdout = std::cout.rdbuf(&stdout_filter);
    auto* old_stderr = std::cerr.rdbuf(&stderr_filter);
    const int result = pepepow_legacy_main(argc, argv);
    std::cout.flush();
    std::cerr.flush();
    std::cout.rdbuf(old_stdout);
    std::cerr.rdbuf(old_stderr);
    return result;
}
