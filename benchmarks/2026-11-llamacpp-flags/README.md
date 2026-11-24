# llama.cpp v1.0.0: a model beyond VRAM, one setting at a time

A side measurement outside the labs, started in November 2026 on `formula` (2× RTX 5060 Ti 16 GB, 64 GB RAM; `docs/hardware.md`). llama.cpp v1.0.0, built from source, runs a MoE model larger than VRAM: Qwen3.8-Flash-Next, 3-bit (IQ3_XXS, about 85 GB). From a baseline, the settings below are switched on one at a time, each step keeping the previous ones, and every step is measured before the next.

Status: setup (toolchain, build, model). Every step with the exact command, expected vs actual: [`journal.md`](journal.md).

## Steps

| Step | Setting | Expected effect | Main metric |
|---|---|---|---|
| 0 | Baseline: the model with plain layer offload | — | all of the below |
| 1 | `--cpu-moe` / `--n-cpu-moe N` | Experts in RAM, attention and shared weights in VRAM | generation t/s, VRAM and RAM |
| 2 | Tuner | llama.cpp's Python tuner (`docs/moe-cache.md` in the source) recommends the cache size and the CPU share for this machine; step 2 runs with its recommendation instead of step 1's hand-picked value | generation t/s, what fits in VRAM |
| 3 | Direct I/O | Weights read past the page cache instead of through mmap | load time, RAM |
| 4 | `-b` / `-ub` | Batch and micro-batch size | prompt processing t/s |
| 5 | Time it | Repeated, timed runs of the final configuration | — |

The order comes from a video (kaiexplainsyt). Its slide names the settings, not always the flags: the flag for each step is taken from `llama-server --help` of the build used, and the tuner's usage from `docs/moe-cache.md` of the same checkout, recorded in the journal, never guessed.

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
| Tuner | Python script from the same checkout, its dependencies in a venv under `~/llama.cpp/v1.0.0/` (not system Python) |
| Model | `~/models/qwen3.8-flash-next-iq3xxs/` (outside the repo), revision and SHA256 of every shard in the journal |
| Ollama | installed, disabled at boot (role `ollama`, `ollama_service_enabled: false`) |

Out of scope here: Strata, a later comparison once llama.cpp is tuned.
