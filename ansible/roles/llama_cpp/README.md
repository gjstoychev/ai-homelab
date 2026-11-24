# llama_cpp

The toolchain for building llama.cpp with CUDA on the host. The build itself is not part of the role: `scripts/build-llamacpp.sh` builds a release tag as the user into `~/llama.cpp/<tag>/`. Side benchmark `benchmarks/2026-11-llamacpp-flags/`.

## What it does

Configuration only; the packages are installed by hand (below) and the role never installs them.

- Adds NVIDIA's signed CUDA apt repository for Ubuntu 24.04 (key in `/etc/apt/keyrings/nvidia-cuda.asc`, source in `/etc/apt/sources.list.d/nvidia-cuda.sources`).
- Pins it in `/etc/apt/preferences.d/nvidia-cuda` (see below), before the repository is added.
- Checks that the build toolchain is installed (`vars/main.yml`): from Ubuntu `build-essential`, `cmake`, `ninja-build`, `git`, `libssl-dev`; from NVIDIA, for CUDA `llama_cpp_cuda_version` (`defaults/main.yml`, 13.0), `nvcc`, the runtime and driver API headers and stubs, CCCL, cuBLAS, `cuobjdump` (to check which GPU architectures a binary contains) and NCCL (multi-GPU tensor split). A missing package fails the role with the dry-run command to start from.
- Checks that NCCL is a `+cuda13.0` build.

No driver, no `cuda` or `cuda-toolkit` meta-package (Nsight and the documentation are several GB).

The toolkit lands in `/usr/local/cuda-13.0/`. llama.cpp itself runs from its build directory (the binaries find their libraries through RPATH) and nothing of it goes into `/usr/local/lib`, where Ollama keeps its own ggml libraries (`/usr/local/lib/ollama/`).

## Installing by hand

On the host, one command at a time; compare each output with the expectation before the next. The repository, key and preferences must be in place first (run the role once; with packages missing it fails at the check, after writing them).

1. Nothing half-installed: `sudo dpkg --audit`
2. Dry run. No line may start with `Inst nvidia-` or `Inst libnvidia-` (that would replace the driver's libraries); NCCL must be `+cuda13.0` from NVIDIA:

   ```bash
   sudo apt-get -s --no-install-recommends install build-essential cmake ninja-build git libssl-dev cuda-nvcc-13-0 cuda-cudart-dev-13-0 cuda-driver-dev-13-0 cuda-cccl-13-0 libcublas-dev-13-0 cuda-cuobjdump-13-0 libnccl2 libnccl-dev | grep -E '^Inst'
   ```

3. The same without `-s`.
4. Run the role again: both checks `ok`.

What the install changes system-wide (2026-11-24): the `cuda-toolkit-*-config-common` packages point `/usr/local/cuda` and `/usr/local/cuda-13` at `cuda-13.0` (update-alternatives) and add `/etc/ld.so.conf.d/000_cuda.conf` and `987_cuda-13.conf`, which put CUDA 13.0's `libcudart` and `libcublas` on every program's library path. Ollama is not affected: it starts its runner with its own `cuda_v13/` directory first, and that directory holds the same versions (`libcudart.so.13.0.96`, `libcublas.so.13.1.1.3`). `libcuda.so` stays the driver's; the toolkit's stub is not on the path.

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
