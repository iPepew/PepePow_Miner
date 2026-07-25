#include "pepepow/core/backend.hpp"

#include <iostream>

int main() {
    pepepow::CpuReferenceBackend backend;
    const auto devices = backend.enumerate_devices();

    std::cout << "PepePowMiner v0.1.0-dev\n";
    std::cout << "Backend: " << backend.name() << '\n';
    std::cout << "Detected devices: " << devices.size() << '\n';

    for (const auto& device : devices) {
        std::cout << "  [" << device.index << "] " << device.name << '\n';
    }

#ifdef PEPEPOW_HAS_CUDA
    std::cout << "CUDA backend: enabled\n";
#else
    std::cout << "CUDA backend: disabled at build time\n";
#endif

    return 0;
}
