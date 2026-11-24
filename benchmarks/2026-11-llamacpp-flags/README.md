# llama.cpp v1.0.0: MoE models beyond VRAM, one setting at a time

A side measurement outside the labs, started in November 2026 on `formula` (2× RTX 5060 Ti 16 GB, 64 GB RAM; `docs/hardware.md`). llama.cpp v1.0.0, built from source, runs MoE models larger than VRAM. From a baseline, the settings below are switched on one at a time, each step keeping the previous ones, and every step is measured before the next. The full series runs on each model, Qwen first.

## Models

| | Qwen3.8-Flash-Next (first, the reference) | DeepSeek-V4-Flash-0731 (second) |
|---|---|---|
| What it is | The open-weight release of Alibaba's Qwen3.8-Flash (API); Qwen4 architecture preview | DeepSeek's V4 Flash, GA checkpoint of 2026-07-31, MIT license |
| Parameters | 125B total, 6B active per token, plus 51B n-gram embeddings; 512 experts, 10 routed + 1 shared active, 48 layers | 284B total, 13B active per token |
| GGUF | IQ3_XXS, 79.1 GiB in 2 shards, `batiai/Qwen3.8-Flash-Next-GGUF` at `1d0ec19c`, architecture `qwen4exp` | UD-IQ1_M, 80.9 GiB in 3 shards, `unsloth/DeepSeek-V4-Flash-0731-GGUF` at `fbbb5b93` (the largest that leaves room; journal, section 7) |
| Why | — | More than twice the active parameters: twice the RAM traffic per token with the experts in RAM, so a different starting point for the same steps, and more for the MoE cache to save |

Not compared: quality. DeepSeek at IQ1_M against Qwen at IQ3_XXS is a speed comparison only. DeepSeek's experts do not fit into RAM even at IQ1_M, so its step 1 is `-ncmoe N` instead of `-cmoe`. DeepSeek V4.1-Flash (552B) does not fit 32 GB of VRAM plus 64 GB of RAM even at 2 bits.

Status: setup. Toolchain and build done (v1.0.0, build 12359); both models downloaded and verified; measurements next. Every step with the exact command, expected vs actual: [`journal.md`](journal.md).

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
