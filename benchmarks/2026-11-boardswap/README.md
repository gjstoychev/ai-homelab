# Board swap: two RTX 5060 Ti on x8/x4 (chipset) vs x8/x8 (CPU lanes)

A side measurement outside the labs, done in November 2026 on `z790`. The
second GPU moved from a chipset Gen4 x4 slot (NZXT N7 Z790) to CPU lanes,
Gen5 x8 (ASUS ROG Maximus Z690 Formula). Everything was measured before the
swap and repeated after it with the same Docker images, model files and
scripts. Along the way: Ollama vs llama.cpp on the same two cards.

Write-up: https://gshell.dev/blog/x8x4-vs-x8x8-local-llm/

## Start here

| File | Content |
|---|---|
| [`results/summary.md`](results/summary.md) | **Before vs after**: findings, models and settings, links, bus bandwidth, tokens/s per engine, load times |
| [`results/tps-after.md`](results/tps-after.md) | Tokens per second for every model, scenario and engine on the current board (x8/x8) |
| [`results/tps-before.md`](results/tps-before.md) | The same on the old board (x8/x4) |
| [`engines.md`](engines.md) | Ollama vs llama.cpp: multi-GPU modes, speed, load times, recommendation per use case |
| [`journal.md`](journal.md) | Every step in order: why, the exact command, expected vs actual, including the failed attempts |
| [`AFTER-SWAP.md`](AFTER-SWAP.md) | The checklist used for the swap and the re-run |

## Raw data and scripts

| Path | Content |
|---|---|
| `before/`, `after/` | Raw output of every step, same file names on both sides (`NN-*.txt`, `.csv`, `.jsonl`) |
| `before/14-run1-official-image/` | First llama-bench run with the official image (repeatability check) |
| `results/*.csv` | Machine-readable tables: `tps-*.csv` (one row per engine, model, scenario and test, with standard deviation, quantization, KV cache type, load time), `nvbandwidth-*.csv`, `llamabench-*.csv` |
| `scripts/` | Everything used: benchmark runners, clients, table and summary generators, the nvbandwidth and llama.cpp+NCCL Dockerfiles |
| `after/cpu-power.csv` | CPU package power, 1 s samples, during all after-swap benchmarks |

## Setup in one table

| | Before | After |
|---|---|---|
| Board | NZXT N7 Z790 | ASUS ROG Maximus Z690 Formula |
| GPU1 link | chipset, Gen4 x4 | CPU, Gen5 x8 |
| GPUs | 2x MSI RTX 5060 Ti 16 GB, driver 580.178.04 | same |
| CPU / RAM | i7-14700, 64 GB DDR5-6000 | same |
| Engines | llama.cpp build 12464 + NCCL 2.32.6, Ollama 0.32.14 (Docker, pinned) | same images |
| Models | 9 GGUF files, Q4_K_M (Llama 3 8B Q4_0), KV cache f16 | same files |
| Differences checked | | kernel 7.0.0-43 (was -38), Intel default CPU power limits, display on the iGPU |

## Re-running

The scripts expect the models in Ollama's store (`/usr/share/ollama/.ollama/models`,
mounted read-only), Docker with the NVIDIA container toolkit, and the images
named in the journal. Order and exact commands: `AFTER-SWAP.md`, section D.
After a run: `scripts/make-tps-table.py <phase>` and `scripts/make-summary.py`.

## Redactions

Server logs had Docker-internal addresses and Ollama's per-container public
key; both are replaced with placeholders. No serial numbers, GPU UUIDs, MAC
or home network addresses were captured in the first place.
