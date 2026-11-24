# Journal

Every step in order: why, the exact command, expected vs actual, verdict. Failed attempts stay in.

## Decisions (2026-11-24)

- **Side benchmark, not a lab.** Closest planned lab: Lab 7 (fitting beyond VRAM).
- **Build from the v1.0.0 tag, natively.** v1.0.0 (2026-11-13) is the first release with semantic versioning; building from the tag gives a known commit, the GPU architecture of these cards and the NCCL of our choice (the board-swap benchmark showed that NCCL 2.25.1 crashes tensor split on these cards and 2.32.6 works).
- **CUDA 13.0, not 13.2.** The driver is 580.178.04 (Ubuntu's `nvidia-driver-580-server-open`), which supports CUDA up to 13.0. A driver upgrade is Lab 1's driver work and would change two things at once.
- **Toolchain as an Ansible role (`llama_cpp`), build as a user script** (`scripts/build-llamacpp.sh`). Nothing is installed into `/usr/local/lib`, so llama.cpp and Ollama (which ships its own ggml libraries in `/usr/local/lib/ollama/`) cannot load each other's libraries. NVIDIA's repository is pinned below Ubuntu so it cannot replace the driver's libraries.
- **Ollama disabled at boot** (`ollama_service_enabled: false`): it stays installed and is started by hand when needed. Both engines compete for the same VRAM and RAM; this model needs all of it.
- **Model download with `hf` from pipx** (`pipx install huggingface_hub`), pinned to a repository commit, not `pip --break-system-packages`.
- **To check before downloading:** the IQ3_XXS size differs between repositories (79.2 GiB in one, 88 GB in another). 32 GB of VRAM plus 62 GiB of RAM leave little room; the real size of the files in the chosen repository decides whether it fits.
- **Step 2, the tuner, is a script, not a flag.** A Python script in the llama.cpp repository (`docs/moe-cache.md`) that calculates the recommended cache size and CPU share for the machine. Its usage and the flags its output maps to are read from `docs/moe-cache.md` of the v1.0.0 checkout after the build (section 3); its full output goes into the journal.

## 1. Toolchain (2026-11-24)

**Why:** nvcc, cuBLAS and NCCL for CUDA 13.0 to build llama.cpp; nothing of it was on the host.

**What happened:** the first version of the role installed the packages itself. The check run (`--check --diff`) showed the repository, key and preferences as expected and stopped at the simulation, as expected in check mode. The real run wrote the configuration, then sat silently in the install task for more than ten minutes: NVIDIA's server slowed to 36–66 KiB/s on the last package (`libnccl-dev`), after about 2.3 MB/s on average for the first 1.5 GB. It was stopped with Ctrl-C while still downloading (`dpkg.log`: nothing installed). Decision: installs run by hand, one command at a time; the role keeps only the configuration and checks the installed state (`CLAUDE.md`, role README).

**Commands** (formula, user shell):

```bash
sudo dpkg --audit; dpkg -l | grep -E 'cuda-nvcc|libcublas|libnccl' || echo "nothing installed yet"
sudo apt-get -s --no-install-recommends install cuda-nvcc-13-0 cuda-cudart-dev-13-0 cuda-driver-dev-13-0 cuda-cccl-13-0 libcublas-dev-13-0 cuda-cuobjdump-13-0 libnccl2 libnccl-dev | grep -E '^Inst'
sudo apt-get install --no-install-recommends cuda-nvcc-13-0 cuda-cudart-dev-13-0 cuda-driver-dev-13-0 cuda-cccl-13-0 libcublas-dev-13-0 cuda-cuobjdump-13-0 libnccl2 libnccl-dev
```

**Expected:** nothing half-installed; the dry run without any `nvidia-*` or `libnvidia-*` package, NCCL `+cuda13.0` from NVIDIA.

**Actual:** dry run: 17 packages, all from NVIDIA's repository, none of the driver's; NCCL `2.28.9-1+cuda13.0` (the pin chose it over Ubuntu's NCCL); cuBLAS `13.1.1.3` (its own version scheme, CUDA 13.0); `cuda-toolkit-config-common` and `cuda-toolkit-13-config-common` from 13.5.37. Install as in the dry run. Afterwards: `nvcc` release 13.0, V13.0.88; driver unchanged (580.178.04); `/usr/local/cuda` and `/usr/local/cuda-13` → `cuda-13.0`; new `/etc/ld.so.conf.d/000_cuda.conf` and `987_cuda-13.conf` put `libcudart.so.13` and `libcublas.so.13` from `/usr/local/cuda/targets/x86_64-linux/lib` into the linker cache; `libcuda.so` stays the driver's.

**Verdict:** as expected. The new library path does not reach Ollama: its runner puts its own `cuda_v13/` first, and that holds the same versions (`libcudart.so.13.0.96`, `libcublas.so.13.1.1.3`).

## 2. Build (2026-11-24)

### 2a. First attempt: failed at the web UI assets

**Command** (formula, user shell): `~/ai-homelab/scripts/build-llamacpp.sh v1.0.0`, with the script's first version (`git clone --depth 1`).

**Expected:** a CUDA build for sm_120 and `build-info.txt`.

**Actual:** the tag resolved to `b1b770d90d94cad9e9ea5b993bdbc383a522fb28` (2026-11-13). CMake found CUDA 13.0.88 and NCCL (`/usr/lib/x86_64-linux-gnu/libnccl.so`), turned architecture 120 into `120a` by itself, and reported "llama.cpp version: 1.0.0-dev". The build stopped at step 386 of 576, "Provisioning UI assets": `UI: downloading from b1` → the `.sha256` was not found → fell back to `latest` → `UI: missing required asset(s): bundle[hash].js, bundle[hash].css, workbox[hash].js`.

**Cause:** llama.cpp derives its build number from `git rev-list --count HEAD` (`cmake/build-info.cmake`); a `--depth 1` clone has one commit, so build 1. The server's web UI is downloaded at build time from the Hugging Face bucket `ggml-org/llama-ui` for version `b<build number>` (`tools/ui/CMakeLists.txt`); `b1` does not exist, and `latest` has a newer file layout than the v1.0.0 validator accepts. llama.cpp's own release workflow clones with full history (`fetch-depth: 0`). Separately, `LLAMA_BUILD_IS_DEV` defaults to ON; `CMakeLists.txt` says to set it OFF when building from a release tag.

**Fix (script):** `git clone --filter=tree:0` (the whole commit history, trees and files only for the checked-out commit) and `-DLLAMA_BUILD_IS_DEV=OFF` for `vX.Y.Z` tags; `build-info.txt` also records the commit count.

### 2b. Second attempt: built

**Command:** `rm -rf ~/llama.cpp/v1.0.0; ~/ai-homelab/scripts/build-llamacpp.sh v1.0.0` (fixed script).

**Expected:** version 1.0.0 without `-dev`, the UI for the real build number, `build-info.txt`.

**Actual** (`~/llama.cpp/v1.0.0/build-info.txt`): `version: 1.0.0 (build 12359, commit b1b770d9)`, `LLAMA_BUILD_IS_DEV=OFF`. GPU code: 149 kernels, all `sm_120a` (llama.cpp replaces 120 with 120a; arch-specific code runs only on compute capability 12.0, which is exactly these cards). `GGML_CUDA_NCCL=ON`, linked against `libnccl.so.2` (2.28.9); `libcudart`, `libcublas` from `/usr/local/cuda` (13.0), `libcuda.so.1` from the driver. FlashAttention KV types built: f16, q4_0, q8_0, bf16, f8_e4m3 (`GGML_CUDA_FA_ALL_QUANTS=OFF`). `--list-devices`: both RTX 5060 Ti, 15710 of 15847 MiB free each.

**Verdict:** as expected. Note: build 12359 is about 100 commits *older* than the llama.cpp in the board-swap benchmark (build 12464, 2026-11-19), so numbers between the two are not from the same code.

## 3. The flags in this build (2026-11-24)

Read from `llama-server --help` and `docs/moe-cache.md` of the v1.0.0 checkout:

| Step | Flag |
|---|---|
| 1 | `-cmoe, --cpu-moe` (all experts in RAM) or `-ncmoe, --n-cpu-moe N` (the first N layers) |
| 2 | Tuner: `python3 scripts/moe-cache-tune.py [--max-mib N] -- <llama-server command>`. Python standard library only, no venv. Starts the server 6 times (two cache sizes × CPU shares 0, 0.5, 0.95), times a few thousand generated tokens, fits the machine's upload and CPU speeds, and recommends `--moe-cache-mib N` (experts kept on the GPUs, split like the layers) and `--moe-cache-cpu-share F` (share of cache misses computed on the CPU instead of uploaded): the lowest share within 5 % of the fastest. Both default to 0, i.e. the cache is off unless set. |
| 3 | `-lm dio` (`--load-mode`: auto = mmap by default; none, mmap, mlock, mmap+mlock, dio) |
| 4 | `-b N` (default 2048), `-ub N` (default 512) |

Found on the way:

- **`--fit` is on by default.** It adjusts every argument that is not set so the model fits into device memory (margin 1024 MiB per GPU, minimum context 4096). A "plain" baseline is therefore not plain unless it sets its placement explicitly or turns fit off.
- **Steps 2 and 3 interact.** `docs/moe-cache.md`: host experts are pinned with `-lm none`, `mlock` or `dio`, but not when mmap'd (the default); the GPUs upload pinned experts at full link speed, "so the CPU share often does not help then". The tuner's recommendation in step 2 is for mmap; with `-lm dio` in step 3 the best share may differ.
- **The tuner loads the model 6 times.** With 62 GiB of RAM the 85 GB model cannot stay in the page cache, so every load reads from the NVMe.

## Open points

- **NCCL 2.28.9 is untested on these cards.** The newest `+cuda13.0` NCCL build in NVIDIA's repository is 2.28.9 (2026-11-24). In the board-swap benchmark 2.25.1 crashed llama.cpp's tensor split and 2.32.6 (a `+cuda12.9` build) worked. NCCL matters only for tensor split, which none of the five steps use (the experts sit in RAM); test it before tensor split is used with this build.
