#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUNFILE=/root/cuda_12.4.1_550.54.15_linux.run
URL=https://developer.download.nvidia.com/compute/cuda/12.4.1/local_installers/cuda_12.4.1_550.54.15_linux.run
PREFIX=/usr/local/cuda-12.4
LOG=/root/cuda124-toolkit-install.log

exec > >(tee -a "$LOG") 2>&1

echo "CUDA124_INSTALL_STAGE=preflight"
DRIVER_BEFORE="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
[[ -n "$DRIVER_BEFORE" ]] || {
  echo "ERROR: NVIDIA driver is not available" >&2
  exit 1
}
echo "DRIVER_BEFORE=$DRIVER_BEFORE"

if [[ -x "$PREFIX/bin/nvcc" ]]; then
  VERSION="$($PREFIX/bin/nvcc --version | awk '/release/ {gsub(",", "", $5); print $5; exit}')"
  if [[ "$VERSION" == 12.4* ]]; then
    echo "CUDA124_ALREADY_INSTALLED=YES"
  else
    echo "ERROR: unexpected nvcc at $PREFIX/bin/nvcc: $VERSION" >&2
    exit 1
  fi
else
  echo "CUDA124_INSTALL_STAGE=download"
  curl -fL --retry 8 --retry-delay 5 --continue-at - "$URL" -o "$RUNFILE"
  chmod 0700 "$RUNFILE"

  echo "CUDA124_INSTALL_STAGE=toolkit_only"
  sh "$RUNFILE" --silent --toolkit --toolkitpath="$PREFIX" --override
fi

[[ -x "$PREFIX/bin/nvcc" ]] || {
  echo "ERROR: CUDA 12.4 nvcc was not installed" >&2
  exit 1
}

ln -sfn "$PREFIX" /usr/local/cuda
cat >/etc/ld.so.conf.d/cuda-12-4.conf <<EOF
$PREFIX/lib64
EOF
ldconfig

DRIVER_AFTER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
[[ "$DRIVER_AFTER" == "$DRIVER_BEFORE" ]] || {
  echo "ERROR: NVIDIA driver version changed unexpectedly: $DRIVER_BEFORE -> $DRIVER_AFTER" >&2
  exit 1
}

NVCC_LINE="$($PREFIX/bin/nvcc --version | tail -n1)"
echo "CUDA124_INSTALL_STAGE=complete"
echo "CUDA124_TOOLKIT_GATE=PASS"
echo "DRIVER_UNCHANGED=PASS version=$DRIVER_AFTER"
echo "NVCC=$PREFIX/bin/nvcc"
echo "NVCC_VERSION=$NVCC_LINE"
