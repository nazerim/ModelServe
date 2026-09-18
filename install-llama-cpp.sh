#!/usr/bin/env bash
# Build llama.cpp with CUDA for WSL2 (RTX 3080 sm_86 + RTX 5070 Ti sm_120).
#
# Why this script exists: Ubuntu 26.04's own `nvidia-cuda-toolkit` is CUDA 12.4,
# which cannot target Blackwell (sm_120 needs CUDA >= 12.8). So we take the
# toolkit from NVIDIA's wsl-ubuntu repo instead. CUDA 13.x accepts host GCC
# 6.x-16.x, so Ubuntu 26.04's default gcc-15 is fine (no gcc pinning needed).
#
# Needs your password for the apt/dpkg steps. llama.cpp source is expected at
# ~/llama.cpp (already cloned).
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults

CUDA_VER="${CUDA_VER:-13-3}"
SRC="${SRC:-$HOME/llama.cpp}"

echo "==> 1/4 build tools"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build ccache git wget ca-certificates

if command -v nvcc >/dev/null 2>&1; then
  echo "==> nvcc already present: $(nvcc --version | tail -1)"
else
  echo "==> 2/4 CUDA toolkit $CUDA_VER from NVIDIA's WSL repo"
  if [ ! -e /etc/apt/keyrings/cuda-archive-keyring.gpg ]; then
    wget -q -O /tmp/cuda-keyring.deb \
      https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring.deb
    sudo apt-get update
  fi
  # Full toolkit (~4 GB). Leaner alternative, usually sufficient for llama.cpp:
  #   sudo apt-get install -y cuda-compiler-$CUDA_VER cuda-cudart-dev-$CUDA_VER \
  #     cuda-libraries-dev-$CUDA_VER cuda-driver-dev-$CUDA_VER
  sudo apt-get install -y "cuda-toolkit-$CUDA_VER"
fi

export PATH="/usr/local/cuda/bin:$PATH"
echo "==> 3/4 configure + build (arch auto-detected as 'native' -> 86 + 120)"
cd "$SRC"
cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DGGML_CCACHE=ON
cmake --build build -j"$(nproc)"

echo "==> 4/4 verify"
./build/bin/llama-cli --version 2>/dev/null | tail -2 || true
echo "-- devices llama.cpp will see --"
./build/bin/llama-server --list-devices 2>/dev/null | tail -5 || true
echo "OK: now run $SRC/build/bin/llama-server, or serve.sh with BIN=..."
