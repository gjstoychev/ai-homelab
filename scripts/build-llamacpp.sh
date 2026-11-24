#!/usr/bin/env bash
# Build llama.cpp from a release tag with CUDA for the RTX 5060 Ti (compute capability 12.0).
#
#   scripts/build-llamacpp.sh [tag]        default: v1.0.0
#
# Runs as the user, needs the toolchain from the Ansible role llama_cpp and installs nothing
# outside ~/llama.cpp: source in <tag>/src, build in <tag>/build, what was built in
# <tag>/build-info.txt, and ~/llama.cpp/current -> <tag> after a successful build.
# The binaries run from <tag>/build/bin (RPATH), never from /usr/local, so they cannot pick
# up Ollama's ggml libraries or the other way round.
set -euo pipefail

tag=${1:-v1.0.0}
root=${LLAMA_CPP_ROOT:-$HOME/llama.cpp}
dir=$root/$tag
cuda=/usr/local/cuda-13.0
url=https://github.com/ggml-org/llama.cpp.git

[[ -x $cuda/bin/nvcc ]] || { echo "missing $cuda/bin/nvcc: run the llama_cpp role first" >&2; exit 1; }
[[ ! -e $dir ]] || { echo "$dir exists; remove it to rebuild" >&2; exit 1; }

# Full commit history, without old trees and files (--filter=tree:0): llama.cpp derives its
# build number from the commit count, and the server's web UI is downloaded at build time
# for that build number. A --depth 1 clone gives build 1, asks for UI version b1, falls back
# to "latest" and fails on its newer file layout.
mkdir -p "$root"
git clone --quiet --filter=tree:0 --branch "$tag" "$url" "$dir/src"

# A release tag (vX.Y.Z) is not a dev build (comment at LLAMA_BUILD_IS_DEV in CMakeLists.txt).
dev=ON
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && dev=OFF

# 120 = the RTX 5060 Ti; one architecture builds faster than llama.cpp's default list
# (llama.cpp turns it into 120a). build-info.txt records what the build compiled for.
cmake -S "$dir/src" -B "$dir/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_IS_DEV="$dev" \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_COMPILER="$cuda/bin/nvcc" \
  -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build "$dir/build" -j "$(nproc)"

bin=$dir/build/bin
cudalib=$(find "$dir/build" -name 'libggml-cuda.so*' -type f | head -n1)
# A failed probe is recorded in the file; it does not abort after a finished build.
set +e
{
  echo "== date";      date -u
  echo "== source";    git -C "$dir/src" describe --tags; git -C "$dir/src" rev-parse HEAD
                       echo "build number (commit count): $(git -C "$dir/src" rev-list --count HEAD)"
  echo "== toolchain"; "$cuda/bin/nvcc" --version | tail -n2; cmake --version | head -n1; gcc --version | head -n1
  echo "== packages";  dpkg-query -W -f '${Package} ${Version}\n' \
                         cuda-nvcc-13-0 libcublas-dev-13-0 libnccl2 nvidia-driver-580-server-open
  echo "== cmake";     grep -E '^(CMAKE_BUILD_TYPE|CMAKE_CUDA_ARCHITECTURES|GGML_CUDA[A-Z_]*|GGML_NATIVE|LLAMA_BUILD_IS_DEV|LLAMA_[A-Z_]*UI[A-Z_]*|[A-Z_]*NCCL[A-Z_]*):' \
                         "$dir/build/CMakeCache.txt"
  echo "== gpu code in $(basename "$cudalib")"
  "$cuda/bin/cuobjdump" --list-elf "$cudalib" | grep -oE 'sm_[0-9]+[a-z]?' | sort | uniq -c
  echo "== libraries"; ldd "$cudalib" | grep -E 'nccl|cublas|cudart|libcuda\.' || true
  echo "== version";   "$bin/llama-server" --version 2>&1
  echo "== devices";   "$bin/llama-server" --list-devices 2>&1
} > "$dir/build-info.txt" 2>&1
set -e

ln -sfn "$tag" "$root/current"
cat "$dir/build-info.txt"
