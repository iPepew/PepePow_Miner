# Dependency inventory — PepeW Miner 1.0

Project: MIT, see ../LICENSE. BLAKE3 1.8.5: CC0 option, see BLAKE3-CC0.txt.
nlohmann/json v3.11.3: MIT, see nlohmann-json-MIT.txt.

One unchanged miner executable is shipped from build39208192790,
source2292825ea66a577a13e61ad63695b890396bf38b. Its recorded link command
includes libpepepow_core.a, libpepepow_cuda.a, libblake3.a,
-lcudadevrt and -lcudart_static. NVIDIA terms apply; see NVIDIA-CUDA.md.
System libstdc++, libc, libm, libgcc_s and loader are required, not bundled.
ELF requirements include GLIBC_2.34 and GLIBCXX_3.4.30.
No NVIDIA driver/toolkit executables or third-party miners are distributed.
