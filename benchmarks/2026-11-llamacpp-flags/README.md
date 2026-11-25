# llama.cpp v1.0.0: MoE models beyond VRAM, one setting at a time

A side measurement outside the labs, started in November 2026 on `formula` (2× RTX 5060 Ti 16 GB, 64 GB RAM; `docs/hardware.md`). llama.cpp v1.0.0, built from source, runs MoE models larger than VRAM. From a baseline, the settings below are switched on one at a time, each step keeping the previous ones, and every step is measured before the next. The full series runs on each model.

Order of the runs: the baselines of both models first (Qwen 0b, Qwen 0a, DeepSeek 0b, DeepSeek 0a), so a model that does not load or fit shows up before the steps; then steps 1 to 5 on Qwen, then on DeepSeek. Nothing on the machine changes between runs (each `.cmd` records the build and driver), so the order does not affect the results.

## Models

| | Qwen3.8-Flash-Next (first, the reference) | DeepSeek-V4-Flash-0731 (second) |
|---|---|---|
| What it is | The open-weight release of Alibaba's Qwen3.8-Flash (API); Qwen4 architecture preview | DeepSeek's V4 Flash, GA checkpoint of 2026-07-31, MIT license |
| Parameters | 125B total, 6B active per token, plus 51B n-gram embeddings; 512 experts, 10 routed + 1 shared active, 48 layers | 284B total, 13B active per token |
| GGUF | IQ3_XXS, 79.1 GiB in 2 shards, `batiai/Qwen3.8-Flash-Next-GGUF` at `1d0ec19c`, architecture `qwen4exp` | UD-IQ1_M, 80.9 GiB in 3 shards, `unsloth/DeepSeek-V4-Flash-0731-GGUF` at `fbbb5b93` (the largest that leaves room; journal, section 7) |
| Why | — | More than twice the active parameters: twice the RAM traffic per token with the experts in RAM, so a different starting point for the same steps, and more for the MoE cache to save |

Not compared: quality. DeepSeek at IQ1_M against Qwen at IQ3_XXS is a speed comparison only. DeepSeek's experts (about 73 GiB) do not fit into RAM even at IQ1_M: it runs the same steps with mmap as three tiers (MoE cache on the GPUs, page cache, NVMe), and step 3 (`-lm dio`, pinned memory) is not possible for it (journal, section 19). DeepSeek V4.1-Flash (552B) does not fit 32 GB of VRAM plus 64 GB of RAM even at 2 bits.

Status: measurements complete for both models (2026-11-25); write-up pending. Every step with the exact command, expected vs actual: [`journal.md`](journal.md).

## Results

Prompt about 4260 tokens, 256 generated; mean ± standard deviation of 5 (steps 0–4) or 10 (step 5) measured requests. Every run: `results/summary.md`; every step with its reasoning: `journal.md`.

| Configuration | Qwen3.8-Flash-Next prompt / generation t/s | DeepSeek-V4-Flash prompt / generation t/s |
|---|---|---|
| 0a naive layer offload (`-fit off -ngl N`) | 334.6 / 16.8 | 131.8 / 6.4 |
| 0b llama.cpp's default (`--fit`) | 340.9 / 38.8 | 145.7 / 14.5 |
| 1 `-cmoe` | 202.7 / 24.4 | 93.7 / 10.7 |
| 2 + MoE cache, the tuner's recommendation | 232.5 / 48.1 | 112.6 / 18.7 |
| 2b + twice the tuner's cache | 258.0 / 54.4 | 126.4 / 21.4 |
| 3 + `-lm dio` | 320.2 / 57.8 | not possible (pinned experts exceed RAM) |
| 4 + `-b 4096 -ub 4096` | 804.3 / 58.0 | 230.5 / 19.9 |
| **best** | **803.1 / 59.5** (5b: CPU share 0) | **244.4 / 20.4** (step 5) |
| **best against 0b** | **prompt 2.4×, generation +53 %** | **prompt +68 %, generation +41 %** |

Best configurations:
- Qwen: `-cmoe --moe-cache-mib 23552 --moe-cache-cpu-share 0 -lm dio -b 4096 -ub 4096`
- DeepSeek: `-cmoe --moe-cache-mib 17664 --moe-cache-cpu-share 0.9 -b 4096 -ub 4096`

What the series found:
- llama.cpp's `--fit` (the default) is already 2.3× faster at generation than naive layer offload, on both models.
- The MoE cache is the largest single gain for generation. `scripts/moe-cache-tune.py` sizes it from the first GPU only, so on two GPUs it recommends about half of what fits; twice its size was 12–14 % faster.
- `-b/-ub 4096` is the largest gain for prompts (Qwen 2.5×, DeepSeek 1.8×), at the price of a smaller cache to fit the compute buffer.
- `-lm dio` helps when the experts fit in RAM (Qwen: prompt +24 %, generation +6 %), and then the CPU share should be 0, not the tuner's mmap-based choice.
- A model whose experts do not fit in RAM (DeepSeek, 76 GB of experts, 62 GiB of RAM) still gains with the cache over mmap (GPU cache, page cache, NVMe), but reads about 10 GB per request from the NVMe: there, RAM is the limit.

## Steps

| Step | Setting | Flag (v1.0.0) | Expected effect | Main metric |
|---|---|---|---|---|
| 0a | Naive baseline | `-fit off -ngl N`: whole layers on the GPUs until VRAM is full, the rest on the CPU (no MoE awareness) | — | all of the below |
| 0b | llama.cpp's default | `--fit` on (the default): all layers on the GPUs, experts of the layers that do not fit moved to the CPU | — | all of the below |
| 1 | CPU MoE | `-cmoe` | Experts in RAM, attention and shared weights in VRAM | generation t/s, VRAM and RAM |
| 2 | Tuner | `--moe-cache-mib N --moe-cache-cpu-share F` from `scripts/moe-cache-tune.py` | The most used experts cached on the GPUs; part of the cache misses computed on the CPU | generation t/s |
| 3 | Direct I/O | `-lm dio` | Weights read past the page cache; host experts pinned | load time, RAM, generation t/s |
| 4 | Batch sizes | `-b N`, `-ub N` | Batch and micro-batch size | prompt processing t/s |
| 5 | Time it | — | Repeated, timed runs of the final configuration | — |

The order comes from a video (kaiexplainsyt). Its slide names the settings, not always the flags: the flag for each step is taken from `llama-server --help` of the build used, and the tuner's usage from `docs/moe-cache.md` of the same checkout (journal, section 3), never guessed.

## Measurement rules

- Cumulative: step N runs with steps 1 to N-1 on. This measures what each step adds on top of the earlier ones, not each flag alone.
- Two baselines: 0a shows what plain layer offload gives, 0b what llama.cpp's built-in `--fit` already gives. Steps 1 to 5 build on `-cmoe`, not on 0b; the question is whether they beat 0b.
- Fixed in every run: `-np 1`, `--cache-ram 0` (no prompt cache), `-t 8`, `-c 4096`, `--host 127.0.0.1`.
- Every configuration is run several times; mean and standard deviation are reported.
- Load times are measured from a cold page cache (`sync; echo 3 | sudo tee /proc/sys/vm/drop_caches`), otherwise the second run reads the model from RAM.
- **Tokens per second for every benchmark**: every step on every model reports prompt processing and generation t/s (mean and standard deviation), in the same table as load time, VRAM per GPU, RAM, GPU and CPU power, and the exact command.
- Nothing else on the GPUs: Ollama stopped (`systemctl is-active ollama` → `inactive`), no other CUDA processes.

## Setup

| | |
|---|---|
| Toolchain | Ansible role `llama_cpp`: CUDA 13.0 (`nvcc`, cuBLAS, NCCL) from NVIDIA's repository, no driver change |
| Build | `scripts/build-llamacpp.sh v1.0.0` → `~/llama.cpp/v1.0.0/` (source, build, `build-info.txt`) |
| Tuner | `~/llama.cpp/v1.0.0/src/scripts/moe-cache-tune.py`, Python standard library only |
| Models | `~/models/<model>-<quant>/` (outside the repo), downloaded with `curl` pinned to a repository commit; revision and SHA256 of every shard in the journal |
| Ollama | installed, disabled at boot (role `ollama`, `ollama_service_enabled: false`) |

Out of scope here: Strata, a later comparison once llama.cpp is tuned.
