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

## 4. Models (2026-11-24)

**Decision:** a second model, DeepSeek-V4-Flash-0731 (284B, 13B active, MIT), runs the same series after Qwen. "Qwen Flash" (Alibaba's Qwen3.8-Flash API) is the same model as the open-weight Qwen3.8-Flash-Next already chosen, so no second Qwen. DeepSeek V4.1-Flash (552B) does not fit 32 GB VRAM + 62 GiB RAM even at about 2 bits. This build supports `deepseek4` and `deepseek41` (`src/llama-arch.cpp`). Every benchmark reports tokens per second (prompt processing and generation) with the other measurements.

**Qwen3.8-Flash-Next IQ3_XXS:** repository `batiai/Qwen3.8-Flash-Next-GGUF`, commit `1d0ec19ce9b05014c6236c2813ce77aef6fbc42a`, 2 shards, 44.71 + 34.41 = 79.12 GiB (Hugging Face API, `?blobs=true`). Downloaded with `curl -fL -C -` from `/resolve/<commit>/`, expected SHA256 from `/api/models/<repo>/revision/<commit>?blobs=true` into `SHA256SUMS`. Header of shard 1: `general.architecture = qwen4exp`, 48 layers, 512 experts, 10 used, expert FFN 640 (shared 640), context 262144, file type 23 (IQ3_XXS), imatrix with 200 chunks, 1224 tensors in 2 shards.

**Verified** (`sha256sum -c SHA256SUMS`: both `OK`):

| Shard | Bytes | SHA256 |
|---|---|---|
| `Qwen3.8-Flash-Next-IQ3_XXS-00001-of-00002.gguf` | 48009476896 | `4e461bef2ce7b528d47934a5c0414783a637809d60f0eb67ed8367f19d486bec` |
| `Qwen3.8-Flash-Next-IQ3_XXS-00002-of-00002.gguf` | 36951306720 | `86755e0cd28ae96492a4606a03518addb6def115bdf517df806ca06ac2f9b38b` |

Download at 1 Gb/s after the server was connected directly to the router (before: 100 Mb/s through an old cable or switch).

**Fit (estimate, corrected in section 6):** with `-cmoe` nearly all of the 79 GiB (the experts) goes to RAM, more than the 62 GiB there is; mmap then streams experts from the NVMe while generating. `-ncmoe N` with the GPUs filled (about 30 GiB) leaves about 50 GiB in RAM. Which one step 1 uses is decided after the load log shows the real sizes.

## 5. Smoke test (2026-11-24)

**Why:** does v1.0.0 load and run the model, and where does `--fit` (on by default) put the weights. Not a measurement.

**Command:** `llama-server -m <shard 1> --host 127.0.0.1 --port 8080 -c 4096` (all else default), one `/completion` with 64 tokens, then `free -g` and `nvidia-smi`. Log: `runs/00-smoke.log`.

**Actual:** loads and answers coherently (the model starts with a `<think>` block). Prompt 14 tokens at 39.0 t/s, generation 64 tokens at **37.3 t/s**. VRAM 14782 / 14726 MiB used on GPU0 / GPU1; RAM: 3 GiB used, 59 GiB page cache. The loader warns `tensor overrides to CPU are used with mmap enabled - consider using --load-mode none`: `--fit` moved part of the weights to the CPU by itself. Server defaults visible in the log: 4 slots (`n_slots = 4`, `-np` auto), 8 threads, reasoning preserved in the chat template. Model loaded in 6.4 s, from a warm page cache (`sha256sum` had just read the files), so not a load time.

**Verdict:** it works. At the default verbosity (3) the log does not show the buffer sizes per device or what `--fit` chose; the next run uses `-lv 4`. For the benchmarks: one slot (`-np 1`), so the KV cache and the scheduling do not depend on the auto value.

## 6. Where the weights go (2026-11-24)

**Command:** as in 5, plus `-np 1 -lv 4`; stopped once listening. Log: `runs/01-layout.log`.

**Sizes** (from `--fit`'s memory breakdowns and `load_tensors`):

| Part | MiB | Where |
|---|---|---|
| Whole model | 81015 | |
| `per_layer_token_embd` (the n-gram embeddings) | 27465 | always CPU, mmap'd, "lazy read enabled" with prefetch: only the rows of the tokens used are read |
| Experts (all 48 layers) | about 51000 | the part that `-cmoe`, `-ncmoe` and `--fit` move |
| Dense weights (attention, DeltaNet, shared experts, norms) | about 2300 | GPU in every configuration |
| KV cache at 4096 tokens | 96 + 24 (indexer) | only 12 of 48 layers have attention KV; the other 36 are recurrent (DeltaNet, 113 MiB state) |

**What `--fit` chose by itself:** all 49 layers on the GPUs (13 on CUDA0, 36 on CUDA1), but the experts of 25 layers (and one gate) overflow to the CPU: CUDA0 13878 MiB, CUDA1 14210 MiB of weights, CPU 52927 MiB mapped (27465 n-gram embeddings + about 25000 of experts). About half of the experts stay on the GPUs, placed statically by layer.

**Other defaults seen:** prompt cache in RAM up to 8192 MiB (`--cache-ram`), context checkpoints, warm-up run, 8 threads, flash attention auto (enabled), batch 2048 / ubatch 512, `load_mode = mmap`.

**Consequences for the plan:**

- **`-cmoe` fits in RAM.** All experts on the CPU are about 50 GiB, not 75; the n-gram embeddings are read lazily and need not be resident. 62 GiB is tight but enough. The earlier estimate (section 4) counted the embeddings as experts.
- **The default is already a MoE-aware split.** `--fit` keeps about half of the experts on the GPUs (37.3 t/s in section 5). `-cmoe` moves all of them to RAM and leaves the GPUs nearly empty (about 2.3 GiB of dense weights); the MoE cache (step 2) then fills the VRAM with the most used experts instead of whole layers. The question the series answers is whether a dynamic cache beats `--fit`'s static per-layer placement.
- **Fixed for every run:** `-np 1`, `--cache-ram 0` (no prompt cache: a repeated benchmark prompt would otherwise be served from it, and it takes up to 8 GiB of RAM), `-t 8`, `-c 4096` unless a step changes it.

**Decision (2026-11-24): two baselines.** 0a naive layer offload (`-fit off`, `-ngl` as high as fits), 0b llama.cpp's default (`--fit` on). Steps 1 to 5 build on `-cmoe` and are compared with both.

## 7. DeepSeek-V4-Flash quant (2026-11-24)

**Repository:** `unsloth/DeepSeek-V4-Flash-0731-GGUF`, commit `fbbb5b93fb787c21338159b0af3318bb3f4d9768`. Quants and total sizes (Hugging Face API): UD-IQ1_S 76.9 GiB, UD-IQ1_M 80.9, UD-IQ2_XXS 84.6, UD-IQ2_M 84.7, UD-Q2_K_XL 90.2, UD-IQ3_XXS 97.1, UD-IQ3_S 108.1, UD-Q3_K_M 119.3, UD-Q3_K_XL 119.4, UD-IQ4_XS and UD-IQ4_NL 127.3, UD-Q4_K_XL 144.4, UD-Q8_K_XL 150.8 GiB (plus `dspark` files of about 10 GiB, not used). Q8_K_XL at 150.8 GiB for 284B parameters means the experts are about 4-bit in the original release, so the quant names are not comparable with Qwen's.

**Budget:** about 29 GiB of VRAM for weights plus about 59 GiB of RAM, minus the OS, the KV cache and compute buffers: about 85 GiB. Unlike Qwen (27 GiB of its 79 GiB are lazily read n-gram embeddings), nearly all of DeepSeek's file has to be resident.

**Choice: UD-IQ1_M, 80.9 GiB in 3 shards**, about 4–5 GiB to spare. IQ2_XXS and IQ2_M (84.6/84.7) leave about none: out-of-memory or constant NVMe reads. Quality at this size is clearly reduced; the series compares speed only.

**Consequence (estimate until the load log):** the experts alone are well over 62 GiB, so `-cmoe` (all experts in RAM) does not fit in RAM with any of these quants. For DeepSeek, step 1 is `-ncmoe N` (experts of N layers on the CPU, the rest on the GPUs); the MoE cache works with `-ncmoe` too (`docs/moe-cache.md`).

**SHA256** (expected from `/api/models/<repo>/revision/<commit>?blobs=true`; `sha256sum -c SHA256SUMS`: all three `OK`):

| Shard | SHA256 |
|---|---|
| `DeepSeek-V4-Flash-0731-UD-IQ1_M-00001-of-00003.gguf` | `b99fa246a10808146e00a7e908c6852098a4f08394eabf8b37c9263993980a69` |
| `DeepSeek-V4-Flash-0731-UD-IQ1_M-00002-of-00003.gguf` | `c8536187b0e5dbe71e6bbf6086e0d3b491cd31d60da6522dfef074133c0ee2ee` |
| `DeepSeek-V4-Flash-0731-UD-IQ1_M-00003-of-00003.gguf` | `80a4eb4eebc57598d9559c2924054d40d69f51773ae873538939382e120b3e3f` |

Sizes: 5257664 + 49448084864 + 37447971424 bytes = 80.93 GiB; shard 1 holds only the metadata. Header: `general.architecture = deepseek4` (supported by this build), size label `256x8.4B`, 43 layers, 256 experts with 6 used plus 1 shared, expert FFN 2048, one KV head (64 attention heads) plus an attention indexer, context 1048576 (original 65536), file type 31 (IQ1_M), 1328 tensors in 3 shards.

## Open points

- **NCCL 2.28.9 is untested on these cards.** The newest `+cuda13.0` NCCL build in NVIDIA's repository is 2.28.9 (2026-11-24). In the board-swap benchmark 2.25.1 crashed llama.cpp's tensor split and 2.32.6 (a `+cuda12.9` build) worked. NCCL matters only for tensor split, which none of the five steps use (the experts sit in RAM); test it before tensor split is used with this build.
