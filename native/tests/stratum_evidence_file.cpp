#include "pepepow/stratum/evidence_file.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>

namespace {
void require(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }
}

int main() {
    char directory[] = "/tmp/pepew-evidence-file-XXXXXX";
    if (!::mkdtemp(directory)) return 1;
    struct Cleanup {
        const char* path;
        ~Cleanup() { std::error_code error; std::filesystem::remove_all(path, error); }
    } cleanup{directory};
    try {
        const auto path = std::string(directory) + "/evidence.jsonl";
        pepepow::stratum::EvidenceFile sink(path);
        const std::string line = "{\"event\":\"synthetic\"}\n";
        sink.write(line);
        bool refused = false;
        try { pepepow::stratum::EvidenceFile duplicate(path); }
        catch (const std::exception&) { refused = true; }
        require(refused, "existing evidence file was overwritten");
        struct stat status{};
        require(::stat(path.c_str(), &status) == 0 && (status.st_mode & 0777) == 0600,
                "evidence permissions are not owner-only");
        sink.close();
        sink.close();
        refused = false;
        try { sink.write(line); } catch (const std::exception&) { refused = true; }
        require(refused, "closed sink did not report failure");
        std::ifstream input(path);
        std::string content((std::istreambuf_iterator<char>(input)), {});
        require(content == line, "JSONL bytes changed");
        const auto link = std::string(directory) + "/link";
        std::filesystem::create_symlink(path, link);
        refused = false;
        try { pepepow::stratum::EvidenceFile symlink(link); }
        catch (const std::exception&) { refused = true; }
        require(refused, "symlink path was accepted");
        std::cout << "PASS: exclusive owner-only JSONL sink; existing files/symlinks refused; write failure exposed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
