# Lab 0b — systemd as a Platform

Date: 2026-10-15 · Z790, Ubuntu 24.04, kernel 7.0.0-38-generic, cgroup v2, systemd 255 (255.4-1ubuntu8.17), Ollama 0.32.14, 2× RTX 5060 Ti 16 GB, 64 GB RAM, 8 GiB swap file. Guide: `docs/guides/lab0b.md` (step numbers below refer to it).

## Goal

Run Ollama and a self-written service under systemd with resource limits and sandboxing directives, deployed by Ansible; measure the hardening with `systemd-analyze security`; use `systemd-run --scope` for ad-hoc limits.

Success criteria (`docs/roadmap.md`), all met:

- Ollama and a second service as systemd services with `MemoryMax`, `CPUQuota`, `Restart=on-failure`, `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`: roles `ollama` and `lab0b_demo`.
- `systemd-analyze security` raised: Ollama 9.2 UNSAFE → 1.4 OK, the demo 8.2 EXPOSED → 0.9 SAFE.
- Ad-hoc limits with `systemd-run --scope -p MemoryMax=…`.

The second service is a small demo created for the lab: `python3 -m http.server` with a secret in an `EnvironmentFile`.

## What I did

1. Where commands run: Claude Code in its sandbox reads files and writes roles; everything that talks to systemd is run by the user (step 1).
2. Versions: systemd 255; Ollama 0.32.14 stays, while GitHub's latest release is 0.40.4 (checked 2026-10-15); upgrading is not part of this lab (step 2).
3. Ollama today: the install script's unit plus a drop-in with `OLLAMA_HOST=0.0.0.0:11434` (other clients on the server) and a GPU-wait `ExecStartPre` (guard against a start-up race that leaves Ollama on the CPU); no limits, no sandboxing (step 3).
4. Baseline `systemd-analyze security`: 9.2 UNSAFE, 75 of 81 checks failed (step 4).
5. Second service: a demo `python3 -m http.server` with a secret in an `EnvironmentFile` (step 5).
6. `systemd-run --scope -p MemoryMax=100M -p MemorySwapMax=0`: an OOM kill inside the scope; with the default `OOMPolicy=stop` systemd then stops the whole unit (step 6).
7. Ollama's memory with models loaded: mostly page cache of model files, including unloaded models (23.1 GiB counted, 1.4 GiB `anon` + `shmem`); with one card disabled for the test, a model partly on the CPU maps its CPU layers from the file, and the KV cache of those layers is anonymous memory (640 MiB at 32768 tokens). Decision: `MemoryHigh=16G`, `MemoryMax=32G` (step 7).
8. Design: Ollama's installer rewrites its unit on every run, so the role `ollama` manages drop-ins only; the demo's secret is a root-only file created by hand; the demo lives in its own role (step 8).
9. Role `ollama`, first round: `Restart=on-failure`, `OOMPolicy=continue`, start limit 5 in 5 minutes (the default never triggers with `RestartSec=3`), `NoNewPrivileges`, `PrivateTmp`; 9.2 → 8.7 (step 9).
10. `ProtectSystem=strict` with `ReadWritePaths=` for `~/.ollama` and `~/.nv` (Ollama's home is under `/usr`), `ProtectHome=yes`; 8.7 → 8.3 (step 10).
11. Devices: `DevicePolicy=closed`, `DeviceAllow=char-nvidia rw`, `char-nvidia-uvm rw`, `modprobe@nvidia_uvm` before Ollama; a negative test proves other devices are refused; 8.3 → 8.2 (step 11).
12. Resource limits from measurements: one runner entirely on the CPU uses 8 threads (≈ 790%), 76 tasks at peak; `CPUQuota=1600%`, `TasksMax=512`. `MemoryHigh` keeps the cgroup under 16 GiB by reclaiming page cache, without an OOM; the quota does not throttle (step 12).
13. Kernel, process and privilege restrictions, 16 directives; 8.2 → 3.4 (step 13).
14. Regression tests: write path, pull, embeddings, a client in a container, a two-card model, an image through the vision encoder, CPU speed; all pass (step 14).
15. Five risky directives one at a time with a temporary runtime drop-in: `RestrictAddressFamilies`, `SystemCallFilter=@system-service` with `SystemCallErrorNumber=EPERM`, `PrivateUsers`, `MemoryDenyWriteExecute` pass; `ProcSubset=pid` is left out; then `SystemCallFilter=~@privileged`. A model entirely on the CPU turns out to be loaded without mmap. 3.4 → 1.4; regression tests pass again (step 15).
16. Demo service, role `lab0b_demo`: `DynamicUser=yes`, `StateDirectory=`, `EnvironmentFile=` (root:root `0600`, asserted by the role); the secret reaches the process, neither another user nor the service user can read it; 8.2 (step 16).
17. Demo hardening: the Ollama set plus `PrivateDevices`, `ProcSubset=pid`, `IPAddressDeny=any`/`IPAddressAllow=localhost`, `~@resources`, `UMask=0077`, `AF_INET` only; outgoing traffic from its cgroup times out; 8.2 → 0.9 SAFE (step 17).
18. Deliberate failures: `kill -9` (restart in 4 s), a crash loop (stopped by the start limit), OOM in both services; the swap finding adds `MemorySwapMax=0` to both (step 18).
19. Final checks: lint clean on both control points, `site.yml` idempotent (`changed=0`), and after a reboot both services start on their own with the same scores (step 19).

## Measurements

| Item | Value |
|---|---|
| systemd | 255 (255.4-1ubuntu8.17), Ubuntu 24.04 |
| Ollama | 0.32.14, `/usr/local/bin/ollama` |
| Ollama releases (GitHub, 2026-10-15) | 0.40.4 (2026-10-12), 0.40.1 (2026-10-07), 0.40.0 (2026-09-25), 0.35.x, 0.34.x |

`systemd-analyze security` (2026-10-15):

| Step | What was added | `ollama.service` | `lab0b-demo.service` |
|---|---|---|---|
| 4 | nothing (installer's unit + drop-in) | 9.2 UNSAFE | |
| 9 | `NoNewPrivileges`, `PrivateTmp` (+ restart policy, start limit, `OOMPolicy`) | 8.7 EXPOSED | |
| 10 | `ProtectSystem=strict`, `ReadWritePaths=`, `ProtectHome` | 8.3 EXPOSED | |
| 11 | `DevicePolicy=closed`, `DeviceAllow=` | 8.2 EXPOSED | |
| 13 | kernel, process and privilege restrictions (16 directives) | 3.4 OK | |
| 15 | `RestrictAddressFamilies`, `SystemCallFilter`, `PrivateUsers`, `MemoryDenyWriteExecute`; then `~@privileged` | 1.5 OK; **1.4 OK** | |
| 16 | `DynamicUser`, `StateDirectory`, `EnvironmentFile` | | 8.2 EXPOSED |
| 17 | the Ollama set plus `PrivateDevices`, `ProcSubset=pid`, `IPAddressDeny`/`Allow`, `~@resources`, `UMask=0077` | | **0.9 SAFE** |
| 19 | after a reboot | 1.4 OK | 0.9 SAFE |

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
| `qwen3.8:27b`, one card (the other disabled for Ollama), page cache dropped first | 18 GB, 25%/75% CPU/GPU, context 4096 | 17.60 GiB | 671 MiB | 16.92 GiB | 4.23 GiB | 154 MiB | 14324 / 2 MiB |
| same, `num_ctx` 32768 | 18 GB, 35%/65% CPU/GPU, context 32768 | 18.30 GiB | 1.30 GiB | 16.98 GiB | 5.53 GiB | 210 MiB | 14390 / 2 MiB |

`llama-server` (the runner) in the one-card case, and the same model entirely on the CPU: `Rss` 4.91 GiB = `Pss_File` 4.13 GiB (CPU layers, mapped from the model file) + `Pss_Anon` 639 MiB; with context 32768: `Rss` 6.85 GiB = `Pss_File` 5.38 GiB + `Pss_Anon` 1.26 GiB. llama.cpp's log for the 32768 load: CPU KV buffer 640 MiB, CUDA0 KV buffer 1408 MiB, CUDA0 model buffer 10665.58 MiB; the growth of `anon` (0.63 GiB) is the CPU part of the KV cache. `llama3.1:8b` entirely on the CPU (`num_gpu: 0`, context 32768): `load_mode = none` (mmap disabled), cgroup `anon` 8.69 GiB, `file_mapped` 0; `llama-server` `Pss_Anon` 8.65 GiB.

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

Ollama after the lab (2026-10-15): drop-ins `hardening.conf` and `override.conf` (role `ollama`); `MemoryHigh` 16 GiB, `MemoryMax` 32 GiB, `MemorySwapMax` 0, `CPUQuotaPerSecUSec` 16s, `TasksMax` 512; both cards found 4–6 s after the start; 13.5 tokens/s on the CPU, as before.

Deliberate failures (2026-10-15):

| Test | Result |
|---|---|
| `kill -9` Ollama | restarted after 4 s, `NRestarts=1`, both cards back |
| 5 more kills within a minute | 6th start refused, `failed`, `Result=signal`, `NRestarts=6` |
| 200 MB in the demo's cgroup, `MemoryMax=64M`, no swap limit | no OOM: `memory.peak` 64 MiB, `memory.swap.peak` 155 MiB, `max 629` |
| the same with `MemorySwapMax=0` | `exit=137`, `Result=oom-kill`, restarted (`NRestarts=1`) |
| 6 GiB in Ollama's cgroup, `MemoryMax=4G` (temporary), `OOMPolicy=continue` | victim killed (`oom_kill 1`), same `MainPID`, `NRestarts=0` |

## What surprised me

The biggest gap was not a directive I missed but one I assumed: `MemoryMax=` limits RAM only, and on a host with swap a service above its limit quietly moves to swap instead of being stopped; until `MemorySwapMax=0` the memory limits did not do what they say. Ollama's memory was the second surprise: what its cgroup counts is mostly page cache of model files, even of models already unloaded, and whether the CPU part of a model can be reclaimed depends on how Ollama loads it (mapped from the file when the model is partly on the GPU, all anonymous memory when it is entirely on the CPU). Hardening a CUDA service went further than expected: 1.4 OK with system call filtering, a private user namespace and no writable-executable memory, and what blocks the last points is the GPU device list, the network and `/proc/meminfo`, not CUDA. The failures that matter were the silent ones: a GPU service without its devices runs on the CPU, `ProcSubset=pid` leaves Ollama blind to system memory with only a warning, and an IP filter shows up as a timeout.

Details:

- `MemoryMax=` limits RAM only; `MemorySwapMax=` is separate and unlimited by default.
- Unloading a model frees VRAM, not the page cache of its file; Ollama's `memory.current` grows with every model read.
- With a model partly on the GPU, its CPU layers are mapped from the model file; with a model entirely on the CPU, Ollama 0.32.14 disables mmap (`load_mode = none`) and everything is anonymous memory (8.65 GiB for `llama3.1:8b` at 32768 tokens). The KV cache of CPU layers is anonymous in both cases.
- Ollama's default context depends on total VRAM (below 24 GiB 4k, 24–48 GiB 32k).
- systemd's default `OOMPolicy=stop` stops the whole unit when one process is OOM-killed; it counts as a failure, and `Restart=on-failure` brings the service back.
- The default start limit (5 starts in 10 s) never triggers for a service with `RestartSec=3`. `NRestarts` counts the restart the limit refuses, and `Result=` keeps the last process failure; the start limit is visible only in the journal.
- `DevicePolicy=`/`DeviceAllow=` apply to the whole cgroup: the `+` prefix of `ExecStartPre=` does not bypass them, and a `DeviceAllow=` group missing at start is silently dropped.
- `MemoryDenyWriteExecute=yes` does not break CUDA here (no JIT for these cards).
- `SystemCallFilter=@system-service`, systemd's own set for services, still contains privileged calls and `@resources`.
- `ProcSubset=pid` does not break the GPU but `/proc/meminfo`.
- `DynamicUser=yes` implies six protections, yet the score stays at 8.2: they weigh little.
- `IPAddressDeny=` drops packets: a blocked connection times out instead of failing with "permission denied".
- `ProtectClock=yes` adds `DeviceAllow=char-rtc r`, even next to `PrivateDevices=yes`.

## Mistakes and dead ends

- **`ProcSubset=pid` for Ollama** (step 15): every functional test passes, but Ollama logs `error looking up system memory … open /proc/meminfo: no such file or directory` and decides blind whether a model fits. Not used.
- **Memory limits without a swap limit** (step 18): the first OOM test on the demo allocated 200 MB under `MemoryMax=64M` without an OOM; 155 MiB went to swap. Both services now have `MemorySwapMax=0`.

## Open questions

- Device discovery at start takes 4–6 s after the hardening rounds (3 s after step 11); not investigated.
- `sock_throttled 8` in `memory.events` during the `MemoryHigh` test: socket memory throttled under memory pressure; its effect on clients was not measured.
- How much does `MemoryHigh=16G` throttle when two models run entirely on the CPU (anonymous memory above the limit, nothing to reclaim)? Not tested.
- `MemoryDenyWriteExecute=` and the paths in `ReadWritePaths=` depend on Ollama's version; re-run the regression tests (step 14) after every upgrade.

## Follow-ups for later labs

- Lab 0c: Ollama listens on all interfaces for other clients on the server; the firewall decides what reaches it. `IPAddressAllow=`/`IPAddressDeny=` on the unit is a second, per-service layer to compare with nftables.
- Lab 1: Ollama's version (0.32.14 here, 0.40.x released) and an upgrade procedure that re-runs the regression tests; the swap policy of the host; Ollama's installation itself into a role.
- Lab 2: alerts on what systemd records but nobody watches: units in `failed` (start limit), `NRestarts`, and `memory.events` (`oom_kill`, `high`, `max`) per service.
- Lab 4 and Lab 7: models partly or entirely on the CPU change Ollama's memory from reclaimable page cache to anonymous memory; size `MemoryHigh`/`MemoryMax` with that in mind.
- Lab 8: with a gateway in front of Ollama, `IPAddressAllow=` can narrow Ollama to the gateway.
- Lab 11: systemd's directives are a fifth sandbox to compare (`systemd-run -p …` around a command): seccomp, namespaces, an IP filter, device rules, without a container runtime.
- `lab0b_demo`: remove the role, its unit, the secrets file and `/var/lib/private/lab0b-demo` when the lab is no longer needed (its README).

## Step-by-step guide

[docs/guides/lab0b.md](../docs/guides/lab0b.md)
