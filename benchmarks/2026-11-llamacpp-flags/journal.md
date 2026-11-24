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

## 8. Qwen, 0b: llama.cpp's default (2026-11-24)

**Command:** `scripts/run-step.sh qwen3.8-flash-next 0b-fit 5 --` (no step options; the shared ones: `-np 1 --cache-ram 0 -t 8 -c 8192 -lv 4`). Files: `runs/qwen3.8-flash-next/0b-fit.*`.

**Expected:** generation near the smoke test's 37 t/s; prompt speed unknown.

**Actual:** load 24.9 s from a cold page cache. Prompt 4260 tokens at 340.9 ± 3.0 t/s, generation 256 tokens at 38.8 ± 0.4 t/s (5 requests; warm-up 343.0 / 35.7). `--fit` chose the same split as in section 6 (13 layers on CUDA0, 36 on CUDA1 with the experts of 25 overflowing). VRAM peak 14726 / 14890 MiB; server RSS 53.7 GB at the end of loading, 27.7 GB while serving; page cache 54 GB. GPUs 110 W together. CPU package power alternates: 105–114 W for about 5 s while processing the prompt (the CPU computes the experts in RAM), about 42 W while generating; 63 W on average while the requests ran.

**Verdict:** as expected, and very repeatable (standard deviation about 1 %). The CPU average is just under the board's PL1 (65 W over about 28 s, Intel's default since the board swap). Steps with more CPU work (step 4, DeepSeek) may cross it; the CPU power of every run is checked for that.

**Script changes after this run:** `run-step.sh` hands `<step>.cpu.csv` back to the user (sudo wrote it as root) and reports peak server RSS and page cache instead of the lowest `MemAvailable` (with mmap the model's CPU part is page cache, which counts as available). New `scripts/summary.py` writes `results/summary.md` and `.csv` from `runs/`.

**Decision (2026-11-24): order of the runs.** Both models' baselines first (Qwen 0b done, Qwen 0a, DeepSeek 0b, DeepSeek 0a), then steps 1 to 5 on Qwen, then on DeepSeek. DeepSeek at IQ1_M nearly fills VRAM plus RAM; its baselines show early whether it loads and how `--fit` places it. Each run is a fresh server from a cold page cache and nothing on the machine changes between runs, so the order does not affect the results.

## 9. Qwen, 0a: naive layer offload (2026-11-24)

**Command:** `scripts/run-step.sh qwen3.8-flash-next 0a-naive-ngl26 5 -- -fit off -ngl 26`. `-ngl 26` from the layout (section 6): a full layer is about 1.1 GiB, `--fit` found room for 13 per GPU, the output layer is about 0.4 GiB.

**Expected:** it fits; generation clearly below 0b.

**Actual:** fits: output layer plus 25 repeating layers on the GPUs (CUDA0 14311 MiB, CUDA1 13634 MiB of weights), 23 layers on the CPU (53069 MiB mapped, including the n-gram embeddings), with their KV cache in RAM. Peak VRAM 15216 / 14134 MiB; GPU0 had about 630 MiB left, less than one more layer, so 26 is the maximum. Load 17.9 s. Prompt 334.6 ± 3.0 t/s, generation **16.8 ± 0.1 t/s** (warm-up 236.1 / 18.0). GPUs 90 W, CPU 65 W on average while the requests ran (peaks 137 W).

**Verdict:** as expected. `--fit` (0b) generates 2.3× faster with the same VRAM: 0a runs 23 complete layers, attention included, on the CPU; `--fit` keeps every layer on the GPUs and moves only experts. Prompt processing barely differs (−2 %): for large batches the CPU-side weights are copied to the GPUs and computed there either way. The CPU average reached PL1 (65 W) for the first time; generation stayed steady (±0.1 t/s), so no visible throttling.

## 10. DeepSeek, 0b: llama.cpp's default (2026-11-24)

**Command:** `scripts/run-step.sh deepseek-v4-flash 0b-fit 5 --`.

**Expected:** it loads (or fails: a result too); slower than Qwen (13B active against 6B); page cache near full.

**Actual:** loads in 43.4 s. Prompt 4188 tokens at 145.7 ± 2.1 t/s, generation 14.5 ± 0.1 t/s (warm-up 45.2 / 14.8: the first prompt read experts from the NVMe). `--fit`'s memory breakdowns: everything on the GPUs would need 41.7 + 41.8 GiB; the dense weights are about 10 GiB (Qwen: 2.3), the experts about 73 GiB. `--fit` placed all 44 layers (43 + output) on the GPUs, CUDA0 7 layers (1 overflowing), CUDA1 37 (33 overflowing): CUDA0 12594 MiB, CUDA1 14114 MiB of weights, 56163 MiB of experts mapped on the CPU. Peak VRAM 14536 / 14718 MiB; page cache 61.7 GB of 62.5 GiB; KV cache well under 100 MiB in total (compressed attention, several small caches). GPUs 95 W, CPU 53 W on average while the requests ran (peaks 145 W).

**Verdict:** it fits, at the edge: the page cache is nearly all of RAM, but generation is steady (±0.1 t/s), so no experts are re-read from the NVMe while serving. The experts (about 73 GiB) confirm that `-cmoe` cannot fit in RAM; DeepSeek's step 1 stays `-ncmoe N`. Note: this log contains bytes that make `grep` treat it as binary; read it with `grep -a`.

## 11. DeepSeek, 0a: naive layer offload (2026-11-24)

**Command:** `scripts/run-step.sh deepseek-v4-flash 0a-naive-ngl14 5 -- -fit off -ngl 14`. `-ngl 14` from section 10: a full layer is about 2 GiB (`--fit` fitted 7 on CUDA0 in 14.2 GiB), the output layer about 1.5 GiB.

**Expected:** fits; 30 whole layers (about 58 GiB) on the CPU, more than RAM next to the OS, so possibly experts re-read from the NVMe while generating: single-digit and uneven generation, a long run.

**Actual:** fits: 14 of 44 layers on the GPUs (CUDA0 13560 MiB, CUDA1 11839 MiB of weights), 57470 MiB on the CPU. Load 39.4 s. Prompt 131.8 ± 2.3 t/s, generation **6.4 ± 0.1 t/s** (warm-up 45.5 / 6.5). Page cache 61.6 GB, lowest MemAvailable 60.8 GB. GPUs 77 W, CPU 57 W. The whole run took 9 minutes.

**Verdict:** slower as expected, but steady (±0.1 t/s): the CPU layers stayed in the page cache, no visible re-reading from the NVMe. Not quite the maximum: the split came out uneven (peak 15236 / 12346 MiB), GPU1 had about 3.5 GiB left, so `-ngl 15` would probably have fit. One more of 30 CPU layers would change generation by a few percent at most; not re-run.

**Baselines, both models:** `--fit` (0b) generates 2.3× faster than naive layer offload (0a) on both: Qwen 38.8 against 16.8 t/s, DeepSeek 14.5 against 6.4 t/s. Prompt processing differs much less (Qwen +2 %, DeepSeek +11 %). Steps 1 to 5 have to beat 0b.

## 12. Qwen, step 1: `-cmoe` (2026-11-24)

**Command:** `scripts/run-step.sh qwen3.8-flash-next 1-cmoe 5 -- -cmoe`.

**Expected:** generation below 0b; the GPUs nearly empty (only the dense weights).

**Actual:** all 49 layers on the GPUs with only their dense weights (CUDA0 980 MiB, CUDA1 1308 MiB), all experts and the n-gram embeddings mapped on the CPU (78726 MiB). Peak VRAM 1954 / 1804 MiB. Load 16.4 s (the fastest so far: only 2.3 GiB go to VRAM). Prompt **202.7 ± 1.6 t/s**, generation **24.4 ± 0.4 t/s** (warm-up 162.8 / 24.4). Page cache 53.3 GB. GPUs 90 W, CPU 61 W.

**Verdict:** as expected for generation: between 0a (16.8) and 0b (38.8), with about 25 GB of VRAM now free for step 2's cache. Not expected: prompt processing dropped 40 % (341 → 203 t/s). Likely cause: each micro-batch (512 tokens) copies the experts it uses, nearly all of them, to the GPUs ("large batches still upload the experts they use", `docs/moe-cache.md`); the 4260-token prompt is 9 micro-batches, so about 9 full uploads, where `--fit` kept half of the experts on the GPUs. Step 4 (`-ub`) is where that should change.

## 13. Qwen, step 2: the tuner (2026-11-24)

**Command:** `python3 ~/llama.cpp/v1.0.0/src/scripts/moe-cache-tune.py --out runs/qwen3.8-flash-next/2-tune --markdown -- <llama-server> -m <model> -np 1 --cache-ram 0 -t 8 -c 8192 -cmoe` (the tuner adds host, port and `-lv 4` itself). Output: `runs/qwen3.8-flash-next/2-tune.txt`, the six server logs in `2-tune/`.

**Actual:**

| Cache MiB | CPU share | t/s | Cache hits |
|---:|---:|---:|---:|
| 5056 | 0 | 29.1 | 75 % |
| 5056 | 0.5 | 33.0 | 69 % |
| 5056 | 0.95 | 41.8 | 67 % |
| 13440 | 0 | 47.3 | 92 % |
| 13440 | 0.5 | 49.4 | 92 % |
| 13440 | 0.95 | 51.0 | 87 % |

Fitted machine: uploads 12.8 GiB/s, CPU 46.7 GiB/s, 15.23 ms per token for everything else. Predicted with a warm cache: 13440 MiB at share 0 48.0 t/s, 0.8 52.9, 0.95 53.7. **Recommended: `--moe-cache-mib 13440 --moe-cache-cpu-share 0.8` (52.9 t/s predicted).**

**Finding: on two GPUs the tuner caps the cache at about half of what fits.** The cache is split across the GPUs like the layers (log: CUDA0 6794 MiB, CUDA1 6643 MiB for 13440), but the tuner sizes it from the first cache device only: `room = free - used - 512` with the free memory and the buffers of CUDA0 (`device_room()` and the lines after `run_server(... small ...)` in `scripts/moe-cache-tune.py`). With `-cmoe` each GPU has about 13.5 GB free, so about 6.5 GB per GPU stay unused. `--max-mib` can only lower the cap. Candidate upstream issue.

**Decision:** step 2 measures the recommendation as is; an extra step 2b measures about twice the cache (25600 MiB, about 12.8 GB per GPU) at the same share 0.8, so only the size changes. Steps 3 to 5 build on the faster of the two.

## 14. Qwen, steps 2 and 2b: the MoE cache measured (2026-11-24)

**Commands:**
- `scripts/run-step.sh qwen3.8-flash-next 2-moecache-13440 5 -- -cmoe --moe-cache-mib 13440 --moe-cache-cpu-share 0.8` (the tuner's recommendation)
- `scripts/run-step.sh qwen3.8-flash-next 2b-moecache-25600 5 -- -cmoe --moe-cache-mib 25600 --moe-cache-cpu-share 0.8` (about twice the cache, same share)

**Expected:** step 2 near the tuner's 52.9 t/s; 2b faster if the cache size is what limits.

**Actual:**

| Step | Cache per GPU (CUDA0 / CUDA1) | Prompt t/s | Generation t/s | Hit rate (small batches) | Peak VRAM MiB |
|---|---|---|---|---|---|
| 2 | 6794 / 6643 MiB | 232.5 ± 2.9 | 48.1 ± 2.2 | 85.2 % | 8754 / 8450 |
| 2b | 12943 / 12655 MiB | 258.0 ± 3.8 | **54.4 ± 2.1** | 94.2 % | 14902 / 14462 |

Generation rose from request to request in both (2: 46.3 → 51.8, 2b: 53.3 → 57.4): with 256 generated tokens per request the cache was still filling. Load 16.4 s in both. CPU 50 / 47 W, GPUs 103 / 107 W. The server's cache statistics at shutdown: 2 uploaded 56.5 GB for small batches and copied 171 GB from the cache for large batches (the prompts); 2b 38.4 GB and 310 GB.

**Verdict:** the MoE cache beats `--fit` (0b, 38.8 t/s): +24 % with the tuner's size, +40 % with twice the cache. The tuner's two-GPU cap (section 13) costs 12 %. Step 2 stayed below the tuner's prediction because the tuner predicts a fully warm cache and these requests are short; the larger spread (±2 instead of ±0.4) has the same cause. Prompt processing is still below 0b (258 against 341 t/s). Steps 3 to 5 build on 2b.

**Before step 3:** `-lm dio` does not map the model, but lazily read tensors still are (`src/llama-model-loader.cpp:1506`: "read_lazy also requires mmap; this condition make sure it's usable even when --load-mode is not set to mmap"). With DirectIO the experts (about 50 GiB) go into pinned RAM and the n-gram embeddings (27 GiB) stay lazy: it fits. With mmap, the experts are read from the NVMe during the first requests, not during loading; with DirectIO during loading. Load times of the two are therefore compared together with the warm-up request.

## 15. Qwen, step 3: `-lm dio` (2026-11-24)

**Command:** `scripts/run-step.sh qwen3.8-flash-next 3-dio 5 -- -cmoe --moe-cache-mib 25600 --moe-cache-cpu-share 0.8 -lm dio`.

**Expected:** longer load (the experts are read during loading, not during the first request); RSS about 50 GB; generation either way (faster uploads from pinned memory, but the CPU share "often does not help then").

**Actual:** both shards "opened with direct I/O (alignment: 4096 bytes)", `load_mode = dio`, the n-gram embeddings still "lazy read enabled". Load 26.1 s (2b: 16.4). Prompt **320.2 ± 2.1 t/s** (2b: 258.0), generation **57.8 ± 1.2 t/s** (2b: 54.4). Load plus the warm-up request: 26.1 + 15.5 + 5.3 = 46.9 s (2b: 16.4 + 25.6 + 6.2 = 48.2 s). Lowest MemAvailable **8.3 GB** (2b: 60.4 GB): the pinned experts are really taken, where mmap'd ones count as available page cache (`Cached` in `/proc/meminfo` includes the pinned buffer too, so RSS and page cache overlap in the summary). GPUs 118 W, CPU 50 W.

**Verdict:** prompt +24 %, generation +6 % over 2b, and steadier. Pinned experts upload faster, which helps the prompt's large batches most. The first finished answer arrives at the same time as with mmap: DirectIO moves the NVMe reads from the first request into loading. The CPU share 0.8 still pays off with pinned memory here (not tested against 0 yet). The cost is RAM: 8.3 GB left. DeepSeek has about 55 GiB on the CPU and nothing read lazily; DirectIO would leave about 4 GB or fail.

## 16. Qwen, step 4: `-b 4096 -ub 4096` (2026-11-24)

**Compute buffer** (two probe starts with `-cmoe`, no cache; the logs were not saved: the pasted command line was split, so `tee` got no file name; the values are from the terminal output): `-ub 4096` needs CUDA0 1443 MiB, CUDA1 870 MiB, pinned host 217 MiB, against 574 / 109 / 27 at `-ub 512`: +868 / +761 MiB. Step 3 left 843 MiB on CUDA0, so the cache had to shrink by about 2 GiB: 25600 → 23552 MiB (11907 / 11642 MiB per GPU).

**Because two things change, a control run (4c) uses the smaller cache with the default batches.**

**Commands** (`O="-cmoe --moe-cache-mib 23552 --moe-cache-cpu-share 0.8 -lm dio"`):
- `scripts/run-step.sh qwen3.8-flash-next 4-ub4096 5 -- $O -b 4096 -ub 4096`
- `scripts/run-step.sh qwen3.8-flash-next 4c-cache23552-ub512 5 -- $O`

A first attempt at step 4 failed in 1 s: the pasted line was split, so `-ub` had no value (`error while handling argument "-ub": expected value for argument`) and `4096` ran as a command. Its files are kept as `runs/qwen3.8-flash-next/4-ub4096-pasteerror.*`; no requests ran. Long commands are given in short lines since.

**Actual:**

| Step | Prompt t/s | Generation t/s | Hit rate | Copied from the cache for prompts | Peak VRAM MiB | GPU W |
|---|---|---|---|---|---|---|
| 3 (cache 25600, ub 512) | 320.2 ± 2.1 | 57.8 ± 1.2 | 94.2 % | — | 15004 / 14562 | 118 |
| 4c (cache 23552, ub 512) | 317.6 ± 3.7 | 56.9 ± 1.4 | 93.7 % | 286 GB | 13966 / 13548 | 117 |
| 4 (cache 23552, ub 4096) | **804.3 ± 4.1** | **58.0 ± 1.4** | 94.0 % | 83 GB | 14940 / 14360 | 140 |

Load 23.8 s for both.

**Verdict:** `-ub 4096` makes prompt processing 2.5× faster: the 4260-token prompt runs as 2 micro-batches instead of 9, so the experts are copied for 2 instead of 9 (83 against 286 GB per run). Generation does not change (one token at a time never uses large batches). The 2 GiB smaller cache costs nothing measurable (4c against 3: within the spread, hit rate 93.7 against 94.2 %).

**Qwen, step 4 against llama.cpp's default (0b):** prompt 804 against 341 t/s (2.4×), generation 58.0 against 38.8 t/s (+49 %), same VRAM, about the same load time.

## 17. Qwen, step 5: the final configuration, timed (2026-11-24)

**Command:** `scripts/run-step.sh qwen3.8-flash-next 5-final 10 -- $O -b 4096 -ub 4096` (step 4's options, fresh server, 10 measured requests).

**Actual:** load 23.8 s; prompt **806.0 ± 3.9 t/s**, generation **57.6 ± 1.9 t/s** (requests 7 and 10 at 54.9 and 54.7, the others 55.2–59.5). VRAM 14940 / 14360 MiB, as in step 4.

**Verdict:** reproduces step 4 (804.3 / 58.0). Qwen's final configuration: `-cmoe --moe-cache-mib 23552 --moe-cache-cpu-share 0.8 -lm dio -b 4096 -ub 4096`.

**Problem found on the way: a stray CPU power sampler.** The failed paste-error attempt (section 16) exited after 1 s; its cleanup sent SIGTERM to `sudo` before `sudo` had started `cpu-power.sh`, so the sampler kept running. It reopens its file by name every second: after the failed files were renamed it created a new `4-ub4096.cpu.csv`, step 4's own sampler then wrote into the same file, and after step 4 the stray one kept adding idle readings (until 21:01, found because step 4's CPU average in the summary dropped from 49 to 39 W). Only that file is affected; t/s, VRAM and GPU power come from other files. Fix: `cpu-power.sh` takes the PID of `run-step.sh` and stops as soon as that process is gone.
Cleanup: the stray sampler was stopped (`sudo pkill -f cpu-power.sh`; its last line 21:02:16). `4-ub4096.cpu.csv` was cut to step 4's run window (20:52:15–20:53:42, from its `.cmd` and `.ram.csv`); within that window both samplers wrote, two valid readings per second of the same counter, both kept. The untrimmed file is kept as `4-ub4096.cpu.csv.with-stray-sampler`. Step 4's CPU average is now 56 W, the same as step 5's (the 49 W shown earlier was already mixed with idle readings).

## 18. Qwen, 5b: CPU share 0 with DirectIO (2026-11-24)

**Why:** `docs/moe-cache.md`: with pinned host experts (`-lm dio`) "the CPU share often does not help"; the tuner chose 0.8 in step 2, with mmap.

**Command:** `scripts/run-step.sh qwen3.8-flash-next 5b-share0 10 -- -cmoe --moe-cache-mib 23552 --moe-cache-cpu-share 0 -lm dio -b 4096 -ub 4096` (step 5 with share 0). First run with the fixed sampler; it stopped with the run.

**Actual:**

| | Prompt t/s | Generation, requests 1–10 | Requests 1–3 | Requests 4–10 | Hit rate | Uploaded (small batches) | CPU W |
|---|---|---|---|---|---|---|---|
| 5 (share 0.8) | 806.0 ± 3.9 | 57.6 ± 1.9 | 57.4 | 57.7 ± 2.0 | 94.5 % | 50.2 GB | 56 |
| 5b (share 0) | 803.1 ± 4.1 | 59.5 ± 2.5 | 56.4 | **60.9 ± 0.9** | 96.5 % | 99.6 GB | 41 |

Difference over all 10 requests +2.0 t/s, Welch t = 1.98.

**Verdict:** share 0 is better once the cache is warm: +5 % and steadier from request 4, and 15 W less CPU. With share 0 every miss is copied into the cache, so it fills better (96.5 against 94.5 % hits); the price is twice the upload traffic, which pinned memory handles. With share 0.8, 80 % of the misses are computed on the CPU and never enter the cache. The tuner's 0.8 fitted mmap (step 2: slow uploads), not DirectIO: steps 2 and 3 interact, as `docs/moe-cache.md` says. Over only 10 requests the difference is borderline (t ≈ 2); over a longer-running server share 0 wins.

**Qwen, best configuration:** `-cmoe --moe-cache-mib 23552 --moe-cache-cpu-share 0 -lm dio -b 4096 -ub 4096`. Against llama.cpp's default (0b, 340.9 / 38.8 t/s): prompt 803 t/s (2.4×), generation 59.5 t/s (+53 %), 60.9 t/s with a warm cache (+57 %); same VRAM, same load time.

## Open points

- **NCCL 2.28.9 is untested on these cards.** The newest `+cuda13.0` NCCL build in NVIDIA's repository is 2.28.9 (2026-11-24). In the board-swap benchmark 2.25.1 crashed llama.cpp's tensor split and 2.32.6 (a `+cuda12.9` build) worked. NCCL matters only for tensor split, which none of the five steps use (the experts sit in RAM); test it before tensor split is used with this build.
