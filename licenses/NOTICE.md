# Dependency inventory — preparation package

Project source: MIT, see ../LICENSE.

Both pinned native CMake configurations request:

- BLAKE3 1.8.5, BLAKE3-team/BLAKE3, used under its CC0 option.
  Included text: LICENSE_CC0 from tag 1.8.5, copied without changes.
  https://github.com/BLAKE3-team/BLAKE3/blob/1.8.5/LICENSE_CC0
- nlohmann/json v3.11.3, MIT.
  Included text: LICENSE.MIT from tag v3.11.3, copied without changes.
  https://github.com/nlohmann/json/blob/v3.11.3/LICENSE.MIT

Build environment: NVIDIA CUDA 12.8.1 development container on Ubuntu 22.04.
No driver library or third-party miner binaries have been added to this package.
ELF inspection of both miner executables reports dynamically required
libstdc++.so.6, libm.so.6, libgcc_s.so.1, libc.so.6 and ld-linux-x86-64.so.2.
These shared system libraries are not bundled.

Versioned-symbol inspection of both miner executables requires GLIBC_2.34 and
GLIBCXX_3.4.30 (among older versions). An image with only older symbol versions
will not load these binaries. This is a measured ELF requirement, not a claim
that all images of a named distribution are supported.

Outstanding before public stable distribution: identify the exact CUDA runtime
and other static components linked into all twelve executables from build/link
records, include applicable redistribution notices, and verify runtime symbol
requirements on the supported HiveOS image. Absence of a dynamic cudart entry
does not prove absence of CUDA runtime code. Project MIT licensing does not
replace NVIDIA or dependency terms. This inventory is not a completed license
or runtime compatibility audit.
