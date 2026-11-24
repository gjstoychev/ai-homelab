# llama_cpp

The toolchain for building llama.cpp with CUDA on the host. The build itself is not part of the role: `scripts/build-llamacpp.sh` builds a release tag as the user into `~/llama.cpp/<tag>/`. Side benchmark `benchmarks/2026-11-llamacpp-flags/`.

## What it does

- Installs the build tools from Ubuntu: `build-essential`, `cmake`, `ninja-build`, `git`, `libssl-dev`, and `python3-venv` for llama.cpp's Python tools (such as the MoE cache tuner), whose dependencies go into a venv, not into system Python.
- Adds NVIDIA's signed CUDA apt repository for Ubuntu 24.04 (key in `/etc/apt/keyrings/nvidia-cuda.asc`, source in `/etc/apt/sources.list.d/nvidia-cuda.sources`).
- Pins it in `/etc/apt/preferences.d/nvidia-cuda` (see below) before the repository is added.
- Simulates the install and stops if it would install or replace any NVIDIA driver package (`nvidia-*`, `libnvidia-*`).
- Installs only what building llama.cpp needs, for CUDA `llama_cpp_cuda_version` (`defaults/main.yml`, 13.0): `nvcc`, the runtime and driver API headers and stubs, CCCL, cuBLAS, `cuobjdump` (to check which GPU architectures a binary contains), and NCCL (multi-GPU tensor split). No driver, no `cuda` or `cuda-toolkit` meta-package (Nsight and the documentation are several GB).

The toolkit lands in `/usr/local/cuda-13.0/`. Nothing goes into `/usr/local/lib`: Ollama keeps its own ggml libraries in `/usr/local/lib/ollama/`, and llama.cpp runs from its build directory (the binaries find their libraries through RPATH), so the two cannot load each other's libraries.

## Why CUDA 13.0

The driver is Ubuntu's `nvidia-driver-580-server-open` (580.178.04), which supports CUDA up to 13.0. A newer toolkit (13.1, 13.2) would build, but its binaries would run only through NVIDIA's minor version compatibility. The board-swap benchmark's images used 13.0 too. Moving to a newer CUDA starts with a driver upgrade, which is Lab 1's driver work, not this role's.

## apt preferences

| Stanza | Why |
|---|---|
| `Package: *`, `Pin: origin developer.download.nvidia.com`, priority 100 | NVIDIA's repository also carries drivers and `libnvidia-*` libraries, some with higher version numbers than Ubuntu's. At 100 (Ubuntu: 500) a package that exists in both keeps coming from Ubuntu, so `apt upgrade` cannot swap the driver's user-space libraries under the running kernel module. Packages only NVIDIA has still install, and updates within the same package name (13.0.x patch releases) still arrive. |
| `libnccl2 libnccl-dev`, `Pin: version *+cuda13.0`, priority 600 | The repository carries NCCL builds for several CUDA versions under the same package names; the newest is built for a CUDA the driver does not support. 600 picks the newest build for 13.0. |

## The signing key

`files/nvidia-cuda.asc` is NVIDIA's CUDA repository key, fetched once and checked by its fingerprint (not downloaded at run time):

```bash
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub -o ansible/roles/llama_cpp/files/nvidia-cuda.asc
gpg --show-keys ansible/roles/llama_cpp/files/nvidia-cuda.asc
```

The fingerprint must end in `3BF8 63CC` (the key ID in the file name). Recorded at the first fetch (2026-11-24):

- `pub rsa4096 2022-04-14 [SC]`, `cudatools <cudatools@nvidia.com>`
- Fingerprint: `EB693B3035CD5710E231E123A4B469963BF863CC`
