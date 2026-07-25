param(
    [ValidateSet(70,75,80,86,89)]
    [int]$Architecture = 70,
    [int]$MaxRegisters = 0
)

$ErrorActionPreference = "Stop"
$BuildDir = "build-cuda-sm$Architecture"

$CMakeArgs = @(
    "-S", ".",
    "-B", $BuildDir,
    "-DPEPEPOW_ENABLE_CUDA=ON",
    "-DPEPEPOW_BUILD_TESTS=ON",
    "-DPEPEPOW_CUDA_PTXAS_VERBOSE=ON",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_CUDA_ARCHITECTURES=$Architecture"
)

if ($MaxRegisters -gt 0) {
    $CMakeArgs += "-DPEPEPOW_CUDA_MAX_REGISTERS=$MaxRegisters"
}

& cmake @CMakeArgs
& cmake --build $BuildDir --config Release --parallel 2 2>&1 | Tee-Object -FilePath "$BuildDir/ptxas.log"

Write-Host "`nptxas summary:"
Select-String -Path "$BuildDir/ptxas.log" -Pattern "ptxas info.*(Used|stack frame|spill stores|spill loads)"
