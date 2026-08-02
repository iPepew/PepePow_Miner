# Archive: `iPepew/PEPEPOW_Miner_Windows`

Archived before deletion of the standalone repository on 2026-08-02.

## Repository audit

- Source repository: `iPepew/PEPEPOW_Miner_Windows`
- Visibility: public
- Default branch: `main`
- Additional branch: `agent/pepepowminer-foundation`
- Foundation branch head: `7dbcfd9bab6f9db5f6abaf1c66e44857ee7f65ba`
- Open draft PR: `#1 Build native PepePowMiner CPU reference foundation`
- PR state at archive time: open, draft, not merged, 60 commits
- Issues found: none

The default branch contained only a README. The additional foundation branch contained the early native C++20/CUDA miner foundation. The repository did not contain the Windows GUI application, installer, release binaries, or the batch files described in its historical README.

All 26 source paths from the foundation branch were checked and are already present in the active repository `iPepew/PepePow_Miner`, where they have subsequently evolved. The old repository is therefore not a source-of-truth dependency for current miner development.

## Foundation branch file manifest

```text
.github/workflows/native-ci.yml
native/CMakeLists.txt
native/README.md
native/include/pepepow/core/backend.hpp
native/include/pepepow/core/header_builder.hpp
native/include/pepepow/core/types.hpp
native/include/pepepow/crypto/blake3.hpp
native/include/pepepow/crypto/hoohash_reference.hpp
native/include/pepepow/crypto/pow.hpp
native/include/pepepow/cuda/cuda_backend.hpp
native/scripts/profile_cuda.ps1
native/scripts/profile_cuda.sh
native/src/app/main.cpp
native/src/benchmark/cuda_benchmark.cpp
native/src/benchmark/warp_divergence_probe.cpp
native/src/core/cpu_backend.cpp
native/src/core/header_builder.cpp
native/src/crypto/blake3.cpp
native/src/crypto/hoohash_reference.cpp
native/src/crypto/pow.cpp
native/src/cuda/cuda_backend.cu
native/src/cuda/hoohash_matrix_reference.cu
native/src/cuda/pow_pipeline_reference.cu
native/src/cuda/warp_divergence_probe.cu
native/tests/core_tests.cpp
native/tests/cuda_tests.cpp
```

## Historical README snapshot

The following text is preserved from commit `146850e660168075c8145feb51ddedfd45164b56`.

---

# PEPEPOW_Miner_Windows

# PEPEPOW Miner

**PEPEPOW Miner** is a Windows GUI launcher for mining PEPEPOW using the **HooHash V110** algorithm.

The application is designed to make PEPEPOW mining easier for regular Windows users by providing a simple graphical interface for CPU and GPU mining through WSL/Ubuntu.

This project is a community GUI launcher. The mining binaries are based on the official Foztor PEPEPOW miners.

Official PEPEPOW miner website:

```text
https://htn.foztor.net/
```

---

## Features

* Windows graphical interface
* CPU mining support
* NVIDIA GPU mining support
* Windows + WSL / Ubuntu integration
* Automatic WSL/Ubuntu preparation
* CUDA Runtime check for GPU mining
* CPU and GPU toggle switches
* Pool, wallet and worker name settings
* Built-in logs for diagnostics
* Dark mining-style interface
* PEPEPOW logo and desktop shortcut icon
* Designed for simple installation via Windows setup file

---

## Mining Algorithm

PEPEPOW uses:

```text
HooHash V110
```

The application is built around PEPEPOW mining and supports CPU/GPU mining workflows for this algorithm.

---

## Official Miners

This GUI launcher uses official Foztor PEPEPOW miner packages:

* `hoo_cpu`
* `hoo_gpu`

Official downloads and instructions are available here:

```text
https://htn.foztor.net/
```

---

## Supported Platform

Current target platform:

```text
Windows 10 / Windows 11
WSL2
Ubuntu
NVIDIA GPU with CUDA support
CPU mining
```

GPU mining requires a working NVIDIA Windows driver and CUDA runtime support inside WSL.

---

## How It Works

PEPEPOW Miner prepares a local WSL/Ubuntu environment and runs the official PEPEPOW mining binaries inside it.

The user only needs to:

1. Install the application.
2. Open PEPEPOW Miner.
3. Set pool, wallet and worker name.
4. Press **TEST MINER**.
5. Press **START MINING**.

The program checks:

* WSL availability
* Ubuntu environment
* CPU miner files
* GPU miner files
* CUDA Runtime for GPU mining
* miner startup logs

---

## Default Pool Example

Example pool field:

```text
stratum+tcp://pool.pepepow.net:39333
```

Users can change the pool address in the settings panel.

---

## Wallet Address

Users must enter their own PEPEPOW wallet address before mining.

The wallet address is stored locally in the application configuration file.

---

## Important Notice

Mining uses real CPU and GPU resources.

Running this miner may:

* increase power consumption
* increase GPU and CPU temperature
* increase fan speed
* reduce battery life on laptops
* trigger antivirus or security warnings because mining software is often classified as PUA / coin miner software

This program does not hide mining activity.
Mining starts only after the user opens the application and presses **START MINING**.

---

## Antivirus / Security Notice

Cryptocurrency mining software may be detected by antivirus programs or Microsoft Defender as:

```text
PUA
CoinMiner
RiskTool
Potentially unwanted application
```

This can happen even with legitimate mining software.

Recommended safe approach:

* download only from trusted sources
* inspect the source code
* build the application yourself
* use official Foztor miner downloads
* do not run mining software from unknown sources

---

## Project Status

Current release:

```text
PEPEPOW Miner v56
```

Main improvements:

* restored PEPEPOW logo
* desktop shortcut icon support
* WSL repair logic
* CUDA Runtime handling
* improved TEST MINER workflow
* improved log encoding
* CPU/GPU mining startup fixes
* Windows installer fixes

---

## Build From Source

Install Python dependencies:

```bat
install.bat
```

Download miner packages:

```bat
download_miners.bat
```

Build the application:

```bat
build_exe.bat
```

Build the Windows installer:

```bat
Build_Setup_FAST_No_Recompress_v56.bat
```

Final installer output:

```text
output\PEPEPOW_Miner_v56_Setup.exe
```

---

## Logs

The application writes diagnostic logs for:

```text
gui.log
test_miner.log
miner_cpu.log
miner_gpu.log
update_miners.log
```

These logs help diagnose:

* WSL issues
* Ubuntu import problems
* CUDA Runtime problems
* CPU miner startup
* GPU miner startup
* pool connection issues

---

## Disclaimer

This project is provided for educational and mining community purposes.

Use it only on your own hardware or on systems where you have permission to run mining software.

The author is not responsible for:

* electricity costs
* hardware damage
* overheating
* pool issues
* wallet mistakes
* antivirus detections
* third-party miner behavior

Always monitor temperature, power usage and system stability while mining.

---

## Credits

PEPEPOW official miners are provided by Foztor.

Official website:

```text
https://htn.foztor.net/
```

Community GUI launcher:

```text
PEPEPOW Miner
```
