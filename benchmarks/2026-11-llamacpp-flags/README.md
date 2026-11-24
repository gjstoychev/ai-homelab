# llama.cpp v1.0.0: a model beyond VRAM, one setting at a time

A side measurement outside the labs, started in November 2026 on `formula` (2× RTX 5060 Ti 16 GB, 64 GB RAM; `docs/hardware.md`). llama.cpp v1.0.0, built from source, runs a MoE model larger than VRAM: Qwen3.8-Flash-Next, 3-bit (IQ3_XXS, about 85 GB). From a baseline, the settings below are switched on one at a time, each step keeping the previous ones, and every step is measured before the next.

Status: setup. Toolchain and build done (v1.0.0, build 12359); model next. Every step with the exact command, expected vs actual: [`journal.md`](journal.md).

## Steps

| Step | Setting | Flag (v1.0.0) | Expected effect | Main metric |
|---|---|---|---|---|
| 0 | Baseline | explicit layer offload (`--fit` is on by default and must be accounted for) | — | all of the below |
| 1 | CPU MoE | `-cmoe` | Experts in RAM, attention and shared weights in VRAM | generation t/s, VRAM and RAM |
| 2 | Tuner | `--moe-cache-mib N --moe-cache-cpu-share F` from `scripts/moe-cache-tune.py` | The most used experts cached on the GPUs; part of the cache misses computed on the CPU | generation t/s |
| 3 | Direct I/O | `-lm dio` | Weights read past the page cache; host experts pinned | load time, RAM, generation t/s |
| 4 | Batch sizes | `-b N`, `-ub N` | Batch and micro-batch size | prompt processing t/s |
| 5 | Time it | — | Repeated, timed runs of the final configuration | — |

The order comes from a video (kaiexplainsyt). Its slide names the settings, not always the flags: the flag for each step is taken from `llama-server --help` of the build used, and the tuner's usage from `docs/moe-cache.md` of the same checkout (journal, section 3), never guessed.

## Measurement rules

- Cumulative: step N runs with steps 1 to N-1 on. This measures what each step adds on top of the earlier ones, not each flag alone.
- Every configuration is run several times; mean and standard deviation are reported.
- Load times are measured from a cold page cache (`sync; echo 3 | sudo tee /proc/sys/vm/drop_caches`), otherwise the second run reads the model from RAM.
- Recorded per run: prompt processing and generation t/s, load time, VRAM per GPU, RAM, GPU and CPU power.
- Nothing else on the GPUs: Ollama stopped (`systemctl is-active ollama` → `inactive`), no other CUDA processes.

## Setup

| | |
|---|---|
| Toolchain | Ansible role `llama_cpp`: CUDA 13.0 (`nvcc`, cuBLAS, NCCL) from NVIDIA's repository, no driver change |
| Build | `scripts/build-llamacpp.sh v1.0.0` → `~/llama.cpp/v1.0.0/` (source, build, `build-info.txt`) |
| Tuner | `~/llama.cpp/v1.0.0/src/scripts/moe-cache-tune.py`, Python standard library only |
| Model | `~/models/qwen3.8-flash-next-iq3xxs/` (outside the repo), revision and SHA256 of every shard in the journal |
| Ollama | installed, disabled at boot (role `ollama`, `ollama_service_enabled: false`) |

Out of scope here: Strata, a later comparison once llama.cpp is tuned.
