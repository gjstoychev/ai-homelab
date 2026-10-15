# Lab 0b — systemd as a Platform

Date: 2026-10-15 · Z790, Ubuntu 24.04, HWE kernel 7.0, cgroup v2. Guide: `docs/guides/lab0b.md` (step numbers below refer to it).

## Goal

Run Ollama and a small demo service under systemd with resource limits and sandboxing directives, measure the hardening with `systemd-analyze security` before and after, and use `systemd-run --scope` for ad-hoc limits.

## What I did

1. Checked that Claude Code's sandbox is active: `/proc/self/attr/current` reads `claude-bwrap (unconfined)` (step 1).
2. Versions: systemd 255 (255.4-1ubuntu8.17); Ollama 0.32.14 stays, while GitHub's latest release is 0.40.4 (checked 2026-10-15); upgrading is not part of this lab (step 2).
3. Ollama today: the install script's unit plus a drop-in with `OLLAMA_HOST=0.0.0.0:11434` (shared by other clients on the server) and a GPU-wait `ExecStartPre` (guard against a start-up race that leaves Ollama on the CPU); no limits, no sandboxing; cgroup `/system.slice/ollama.service` (step 3).
4. Baseline `systemd-analyze security`: `ollama.service` 9.2 UNSAFE (step 4).
5. Second service decided: a demo `python3 -m http.server` with a secret in an `EnvironmentFile` (step 5).
6. Ad-hoc limit with `systemd-run --scope -p MemoryMax=100M`: OOM kill inside the scope; with the default `OOMPolicy=stop` systemd then stops the whole unit (step 6).
7. Memory with a model loaded: `llama3.1:8b` fully on one GPU; the cgroup counts ≈ 5.8 GiB, ≈ 5.3 GiB of it page cache (step 7).
   `qwen3.8:27b` is split over both cards; the cgroup counts ≈ 23.1 GiB, because the page cache of the unloaded first model stays charged to it; `anon` + `shmem` is ≈ 1.4 GiB.
   With one of the two cards temporarily disabled for Ollama (restored afterwards), after dropping the page cache: `qwen3.8:27b` runs 25%/75% CPU/GPU in a separate `llama-server` process; the CPU layers are mapped from the model file (`file_mapped` ≈ 4.2 GiB), not anonymous memory; with a 32768-token context the KV cache of the CPU layers adds 640 MiB of anonymous memory.
   Decision: `MemoryHigh=16G` + `MemoryMax=32G` for Ollama.
8. Design: Ollama keeps its installer-written unit (rewritten on every upgrade) and gets drop-ins from a role `ollama`; the demo service's secret is an `EnvironmentFile` (root, `0600`) created by hand; the demo lives in its own role `lab0b_demo` (step 8).
9. Role `ollama` (drop-ins `override.conf` and `hardening.conf`): `Restart=on-failure`, `OOMPolicy=continue`, start limit 5 in 5 minutes (the default 5 in 10 s never triggers with `RestartSec=3`), `NoNewPrivileges`, `PrivateTmp`; lint clean (20 of 34 files), check and real run `ok=23 changed=2 skipped=2`; running state verified with `systemctl show`; score 9.2 → 8.7 (step 9).
10. `ProtectSystem=strict` with `ReadWritePaths=` for `~/.ollama` and `~/.nv` (Ollama's home is `/usr/share/ollama`, under `/usr`), `ProtectHome=yes`; copy/delete of a model and a generation on the GPU work, no write errors; score 8.7 → 8.3 (step 10).
11. Devices: `DevicePolicy=closed` with `DeviceAllow=char-nvidia rw` and `char-nvidia-uvm rw` (Ollama opens only `nvidiactl`, `nvidia<N>`, `nvidia-uvm`), `modprobe@nvidia_uvm` before Ollama; both cards found through CUDA within 3 s of the start, a two-card model 100% on the GPU; negative test: `/dev/dri/renderD128` and `nvidia-cap2` refused with the rules, opened without; score 8.3 → 8.2 (step 11).
12. Worst case for CPU and tasks: `llama3.1:8b` entirely on the CPU (`num_gpu: 0`) uses 8 threads (≈ 790%), 13.6 tokens/s, task peak 76 (21 idle). Decision: `MemoryHigh=16G`, `MemoryMax=32G`, `CPUQuota=1600%`, `TasksMax=512` (step 12).
    Tests: loading two models (≈ 22 GiB of files read) keeps the cgroup 3.2 MiB below `MemoryHigh` (page cache reclaimed 916 times, no OOM), the model works on the GPUs; a runner on the CPU is not throttled by `CPUQuota=1600%` (13.2 tokens/s, 783%, `nr_throttled 0`).
13. Kernel, process and privilege restrictions (16 directives: `ProtectKernel*`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `PrivateMounts`, empty `CapabilityBoundingSet`, `Restrict*`, `LockPersonality`, `SystemCallArchitectures=native`, `RemoveIPC`, `UMask=0027`); score 8.2 → 3.4 (step 13).
14. Regression tests: copy/delete/pull, embeddings, a client in a Docker container, a two-card model, an image through the vision encoder, CPU speed (13.4 tokens/s, unchanged); all pass, no errors in the journal (step 14).
15. The risky directives one at a time, with a temporary runtime drop-in: `RestrictAddressFamilies`, `SystemCallFilter=@system-service` with `SystemCallErrorNumber=EPERM`, `PrivateUsers=yes` and `MemoryDenyWriteExecute=yes` pass; `ProcSubset=pid` hides `/proc/meminfo` (`error looking up system memory`) and is not used. Along the way: a model entirely on the CPU is loaded without mmap, all anonymous memory (step 15).
    Final: `SystemCallFilter=~@privileged` added (the `@system-service` set still contains privileged calls); score 1.4 OK; the regression tests pass on the final configuration (CPU 13.5 tokens/s).

## Measurements

| Item | Value |
|---|---|
| systemd | 255 (255.4-1ubuntu8.17), Ubuntu 24.04 |
| Ollama | 0.32.14, `/usr/local/bin/ollama` |
| Ollama releases (GitHub, 2026-10-15) | 0.40.4 (2026-10-12), 0.40.1 (2026-10-07), 0.40.0 (2026-09-25), 0.35.x, 0.34.x |

`systemd-analyze security` (2026-10-15):

| Unit | Before | After |
|---|---|---|
| `ollama.service` | 9.2 UNSAFE | 8.7 EXPOSED (step 9: `NoNewPrivileges`, `PrivateTmp`); 8.3 EXPOSED (step 10: `ProtectSystem=strict`, `ProtectHome`); 8.2 EXPOSED (step 11: `DevicePolicy=closed`, `DeviceAllow=`); 3.4 OK (step 13: kernel, process and privilege restrictions); 1.5 OK (step 15: address families, system call filter, `PrivateUsers`, `MemoryDenyWriteExecute`); **1.4 OK** (`SystemCallFilter=~@privileged`) |

Baseline report for `ollama.service`: 81 checks, 6 passed (`User=`, `AmbientCapabilities=`, `SupplementaryGroups=`, `KeyringMode=`, `Delegate=`, `NotifyAccess=`), 75 failed; highest single value 0.5 (`PrivateNetwork=`), then 0.3 (`RestrictNamespaces=~user`, `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_SET(UID|GID|PCAP)`, `RestrictAddressFamilies=~AF_(INET|INET6)` and exotic families).

Ollama before the lab (2026-10-15, idle, no model loaded):

| Item | Value |
|---|---|
| Unit | `/etc/systemd/system/ollama.service` + drop-in `override.conf`; `User=ollama`, `Restart=always`, `RestartSec=3` |
| `MemoryCurrent` / `TasksCurrent` | 576724992 B (≈ 550 MiB) / 21 |
| `MemoryMax` / `CPUQuotaPerSecUSec` / `TasksMax` | `infinity` / `infinity` / 70833 |

`systemd-run --scope -p MemoryMax=100M -p MemorySwapMax=0`, 300 MB allocation (2026-10-15):

| `OOMPolicy` | Shell output | `memory.events` | Unit result |
|---|---|---|---|
| default (`stop`) | `Terminated` | not printed | `Failed with result 'oom-kill'` |
| `continue` | `Killed`, `exit=137` | `max 36`, `oom 1`, `oom_kill 1`, `oom_group_kill 0` | — |

Ollama's cgroup with a model loaded (2026-10-15, default context 32768):

| Model (on disk) | `ollama ps` | `memory.current` | `anon` | `file` | `file_mapped` | `shmem` | VRAM GPU0 / GPU1 |
|---|---|---|---|---|---|---|---|
| none | — | ≈ 550 MiB | | | | | |
| `llama3.1:8b` (4.9 GB) | 9.2 GB, 100% GPU | 5.81 GiB | 524 MiB | 5.28 GiB | 524 MiB | 108 MiB | 8936 / 2 MiB |
| `qwen3.8:27b` (17 GB), after unloading `llama3.1:8b` | 19 GB, 100% GPU (both cards) | 23.11 GiB | 711 MiB | 22.39 GiB | 1.47 GiB | 678 MiB | 10542 / 11008 MiB |
| `qwen3.8:27b`, one card, page cache dropped first | 18 GB, 25%/75% CPU/GPU, context 4096 | 17.60 GiB | 671 MiB | 16.92 GiB | 4.23 GiB | 154 MiB | 14324 / 2 MiB |
| same, `num_ctx` 32768 | 18 GB, 35%/65% CPU/GPU, context 32768 | 18.30 GiB | 1.30 GiB | 16.98 GiB | 5.53 GiB | 210 MiB | 14390 / 2 MiB |

`llama-server` (the runner) in the one-card case: `Rss` 4.91 GiB = `Pss_File` 4.13 GiB (CPU layers, mapped from the model file) + `Pss_Anon` 639 MiB; with context 32768: `Rss` 6.85 GiB = `Pss_File` 5.38 GiB + `Pss_Anon` 1.26 GiB. llama.cpp's log for the 32768 load: CPU KV buffer 640 MiB, CUDA0 KV buffer 1408 MiB, CUDA0 model buffer 10665.58 MiB; the growth of `anon` (0.63 GiB) is the CPU part of the KV cache.

Ollama's cgroup under `MemoryHigh=16G` (2026-10-15, cache dropped first, `llama3.1:8b` then `qwen3.8:27b`):

| Reading | Value |
|---|---|
| `memory.current` after `llama3.1:8b` / after `qwen3.8:27b` | 5.21 GiB / 15.997 GiB (limit 16 GiB) |
| `anon` / `file` | 504 MiB / 15.49 GiB |
| `memory.events` | `high 916`, `max 0`, `oom 0`, `oom_kill 0`, `sock_throttled 8` |

CPU, `llama3.1:8b` entirely on the CPU, 150 tokens:

| | tokens/s | CPU | `nr_throttled` |
|---|---|---|---|
| no quota | 13.6 | 789% | — |
| `CPUQuota=1600%` | 13.2 | 783% | 0 |

## What surprised me

- systemd's default `OOMPolicy=stop`: one process killed by the OOM killer stops the whole unit, not just that process.
- systemd's default start limit (5 starts in 10 s) never triggers for a service with `RestartSec=3`: a permanently broken service restarts forever.
- `DevicePolicy=`/`DeviceAllow=` apply to the whole cgroup: the `+` prefix of `ExecStartPre=` does not bypass them, and a `DeviceAllow=` group missing at start is silently dropped.
- Unloading a model frees VRAM, not the page cache of its file: Ollama's `memory.current` grows with every model read and is mostly cache, not need.
- Layers that do not fit into VRAM are mapped from the model file, not copied into anonymous memory: a memory limit should slow them down (re-reads from disk) rather than kill the process (step 12).
- A model entirely on the CPU is loaded without mmap (`load_mode = none`): weights and KV cache are anonymous memory (8.65 GiB for `llama3.1:8b` at 32768 tokens), unlike the CPU layers of a model partly on the GPU.
- `MemoryDenyWriteExecute=yes` does not break CUDA here: no JIT for these cards.
- `SystemCallFilter=@system-service`, systemd's own set for services, still contains privileged system calls (`chown`, `setuid`, `chroot`, `bpf`) and `@resources`; `systemd-analyze security` marks both.
- `ProcSubset=pid` does not break the GPU, as expected, but `/proc/meminfo`: Ollama keeps running without knowing the system memory, only a warning in the journal.
- Ollama's default context depends on total VRAM (below 24 GiB 4k, 24–48 GiB 32k): one card gives 4096 tokens, two give 32768.
- The only part of a model on the CPU that is anonymous memory is its KV cache; it grows with the context.

## Mistakes and dead ends

## Open questions

- Device discovery at start took 6 s after step 13, 3 s after step 11; not investigated.

## Follow-ups for later labs

## Step-by-step guide

[docs/guides/lab0b.md](../docs/guides/lab0b.md)
