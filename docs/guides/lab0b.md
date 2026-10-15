# Lab 0b — systemd as a Platform: Step-by-Step Guide

Status: complete. Last updated: 2026-10-15. Results on this hardware: `results/lab0b.md`.

## Overview

Two services run under systemd with resource limits and sandboxing directives, deployed by Ansible roles: Ollama (installed with its official script, two RTX 5060 Ti cards) and a small demo service created for the lab (`python3 -m http.server` with a secret in a root-only file). `systemd-analyze security` measures each step: Ollama goes from 9.2 UNSAFE to 1.4 OK, the demo from 8.2 to 0.9 SAFE. On the way: what Ollama's memory really is (page cache, mapped weights, KV cache), which device nodes a CUDA service needs, which directives break it, regression tests after each round, and deliberate failures (kill, crash loop, OOM) to prove the restart and OOM settings. `systemd-run --scope` applies the same limits to any command.

Documentation used: the manual pages of the installed systemd 255 (`systemd.exec(5)`, `systemd.resource-control(5)`, `systemd.service(5)`, `systemd.unit(5)`, `systemd-system.conf(5)`, `systemd-run(1)`, `systemd-analyze(1)`), and Ollama's documentation and install script at tag `v0.32.14` (read 2026-10-15).

## Working conventions

- Same as Lab 0f: each step says where a command runs (node or control node), whether it needs root and whether it changes anything. Ansible runs from `<repo>/ansible` on the control node, always `--check --diff` first.
- Placeholders: `<repo>` is the checkout path, `<user>` the account on the node.
- **Check the running state, not only the file.** Ansible reports what it wrote; `systemctl show` reports what systemd loaded; a functional test reports what the service can still do.

---

## Step 1/19 — Where the commands run

**Why:** in this lab Claude Code runs on the node in its sandbox (Lab 0f): the home directory is read-only, there is no D-Bus, so `systemctl`, `systemd-analyze security`, `systemd-run` and the system journal are not available to it. Claude reads unit files and manual pages and writes the roles; the user runs everything that talks to systemd or needs root, and Ansible from the control node.

**Command** (Claude, sandboxed; read-only): `cat /proc/self/attr/current`

**Result:** `claude-bwrap (unconfined)`, the AppArmor label of the sandbox's bwrap copy (Lab 0f, step 12). A unit and its drop-ins can still be read without D-Bus: `cat /etc/systemd/system/<unit> /etc/systemd/system/<unit>.d/*.conf`.

## Step 2/19 — Versions and documentation

**Why:** directive names and behaviour differ between systemd versions, so they are checked in the manual pages of the installed version (`man systemd.exec`, `systemd.resource-control`, `systemd.service`) and with `systemctl show`, not from memory. Software versions are pinned, preferably to a release at least a few weeks old.

**Command** (node, read-only, no root):

```bash
/usr/lib/systemd/systemd --version | head -1; command -v ollama; ollama --version
curl -fsS 'https://api.github.com/repos/ollama/ollama/releases?per_page=12' | python3 -I -c 'import json,sys; [print(r["tag_name"], r["published_at"][:10], "prerelease" if r["prerelease"] else "") for r in json.load(sys.stdin)]'
man -w systemd.exec systemd.resource-control systemd.service systemd-analyze
```

**Result (2026-10-15):**

- systemd 255 (`255.4-1ubuntu8.17`, Ubuntu 24.04). The four manual pages are installed under `/usr/share/man`.
- Ollama client 0.32.14 in `/usr/local/bin/ollama` (the official install script's location, not an apt package). From the sandbox the client cannot reach the server on `localhost` (Lab 0f, step 23), so the warning "could not connect to a running Ollama instance" says nothing about the service.
- GitHub releases (2026-10-15): 0.40.4 (2026-10-12), 0.40.1 (2026-10-07), 0.40.0 (2026-09-25), 0.35.1 (2026-09-29), 0.34.x (September). The release cadence is high.

**Decision: Ollama version.**

| Option | For | Against |
|---|---|---|
| **A (chosen):** keep 0.32.14 | Every measurement is on what runs today; the only variable is systemd | The version is old; upgrading is a separate topic (Lab 1, update policy) |
| B: upgrade to 0.40.0 | A release three weeks old | A manual root install that can change paths, GPU handling or variables before the baseline |
| C: upgrade to 0.40.1 or later | Newest | Only days old |

The lab changes no Ollama version: installed 0.32.14 stays.

## Step 3/19 — Ollama today: unit, drop-in and cgroup

**Why:** know exactly what runs before changing it: who started it, with which user and options, and in which cgroup.

**Command** (unit files: Claude, read-only; running state: node, no root, read-only):

```bash
cat /etc/systemd/system/ollama.service /etc/systemd/system/ollama.service.d/override.conf
systemctl show ollama -p MainPID,ActiveState,SubState,User,ControlGroup,MemoryCurrent,TasksCurrent,TasksMax,MemoryMax,CPUQuotaPerSecUSec,Restart,NRestarts,FragmentPath,DropInPaths,ExecStartPre
```

`systemctl cat` would show both files in one call but needs D-Bus, which the sandbox does not have.

**Result (2026-10-15):**

`/etc/systemd/system/ollama.service` is the unit written by Ollama's install script (`ExecStart=/usr/local/bin/ollama serve`, `User=ollama`, `Group=ollama`, `Restart=always`, `RestartSec=3`, a `PATH` variable, `WantedBy=default.target`). It has no resource limits and no sandboxing directive. The drop-in `override.conf` adds two things:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
ExecStartPre=+/usr/bin/timeout 60 /bin/sh -c 'until /usr/bin/nvidia-smi -L >/dev/null 2>&1; do sleep 1; done'
```

- `OLLAMA_HOST=0.0.0.0:11434`: other clients on the server use Ollama too, so it listens on all interfaces; what can actually reach the port is decided by the firewall (Lab 0c).
- The `ExecStartPre` waits up to 60 seconds for the GPU driver. It is a guard against a start-up race: without the wait, Ollama does not see both cards and runs on the CPU until the next restart. The `+` prefix runs this command with full privileges, outside the unit's sandboxing (`man systemd.service`, step 9).

Both stay in the hardened configuration.

Running state:

| Property | Value |
|---|---|
| `ActiveState` / `SubState` | `active` / `running` |
| `User` | `ollama` |
| `ControlGroup` | `/system.slice/ollama.service` |
| `Restart` / `NRestarts` | `always` / 0 |
| `MemoryCurrent` | 576724992 B (≈ 550 MiB, no model loaded) |
| `TasksCurrent` / `TasksMax` | 21 / 70833 (the systemd default, as in Lab 0a) |
| `MemoryMax`, `CPUQuotaPerSecUSec` | `infinity`, `infinity` |

## Step 4/19 — Baseline exposure score

**Why:** `systemd-analyze security` scores a unit from 0 (best) to 10 by the directives it sets; it reads the loaded unit, so it works for a stopped service too. The number before any change is the yardstick of the lab.

**Command** (node, no root, read-only):

```bash
systemd-analyze security ollama.service --no-pager
```

**Result (2026-10-15):**

```
UNIT               EXPOSURE PREDICATE HAPPY
ollama.service          9.2 UNSAFE    😨
```

Ollama's unit has no sandboxing directive at all. Per `man systemd-analyze` (systemd 255), the tool assigns each security-related setting an exposure level by how important it is and derives one estimate in the range 0.0–10.0 for the unit; it counts only what systemd itself enforces, not what the program does on its own. A high score means little sandboxing is applied, not that the service is vulnerable.

**The full report** (`systemd-analyze security ollama.service --no-pager`): 81 checks, 6 passed (`User=`, `AmbientCapabilities=`, `SupplementaryGroups=`, `KeyringMode=`, `Delegate=`, `NotifyAccess=`), 75 failed. No single check has an exposure value above 0.5; the unit's score is derived from many small values. The heaviest: `PrivateNetwork=` 0.5; `RestrictNamespaces=~user`, `CapabilityBoundingSet=~CAP_SYS_ADMIN`, `~CAP_SYS_PTRACE`, `~CAP_SET(UID|GID|PCAP)` and `RestrictAddressFamilies=~AF_(INET|INET6)` 0.3 each.

Grouping of the failed checks, as hypotheses to test (each directive is read in the manual page before it is used):

| Group | Directives | Expectation |
|---|---|---|
| Cheap, probably safe | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, `ProtectHome`, `ProtectKernelTunables`/`Logs`/`Modules`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc`, `ProcSubset`, `RestrictSUIDSGID`, `RestrictRealtime`, `LockPersonality`, `RemoveIPC`, `UMask`, `SystemCallArchitectures`, `PrivateMounts` | Work; `ProtectSystem=strict` needs a path for the models |
| Touch the GPU | `PrivateDevices`, `DeviceAllow`/`DevicePolicy`, `ProtectKernelModules`, `CapabilityBoundingSet` | May hide `/dev/nvidia*`: Ollama would fall back to the CPU without an error |
| Touch Go and CUDA | `MemoryDenyWriteExecute`, `SystemCallFilter`, `RestrictNamespaces`, `RestrictAddressFamilies` | `MemoryDenyWriteExecute` could break CUDA (it does not, step 15); the address families must keep INET, INET6 and UNIX |
| Not applicable | `PrivateNetwork` (it serves clients), `PrivateUsers`, `IPAddressDeny` (it downloads models) | Stay failed, so the final score is not 0 |

## Step 5/19 — The second service: a demo

**Why:** a self-written service shows what the packaged Ollama unit cannot: our own unit file, a file with secrets, and a data directory that `ProtectSystem=strict` needs a `ReadWritePaths` entry for. It must be public, neutral and small, with no scripts in the repository.

**Decision:**

| Option | How | For | Against |
|---|---|---|---|
| **A (chosen):** `python3 -m http.server` | Serves a directory under `/var/lib/<demo>` on a loopback port; the secret is a variable from an `EnvironmentFile` | Nothing to install, plain directives without a script, enough for `ReadWritePaths` and limits | The service does not use the secret; the demo shows only the file's permissions and who can see it |
| B: `ExecStart` runs a small shell command that reads the secret | The variable demonstrably reaches the process | A more convincing secrets example | A shell line inside the unit, on the border of the "no scripts" rule |
| C: `LoadCredential=` instead of `EnvironmentFile` | systemd hands the secret to the service as a file only it can read | The modern way | `EnvironmentFile` would not be shown |

`LoadCredential=` stays as a comparison in the secrets decision (step 8).

## Step 6/19 — Ad-hoc limits with `systemd-run --scope`

**Why:** systemd can put any command into a cgroup with limits, without a unit file: the same `memory.max` that Lab 0a wrote by hand under `/sys/fs/cgroup`, now set by the service manager.

**Documentation** (systemd 255): `systemd-run --scope` creates a transient `.scope` unit for a process started by the caller (the default is a transient `.service`, started by systemd); `-p` sets any resource-control property. `MemoryMax=` is "the last line of defense": if usage cannot be kept under it, the OOM killer is invoked inside the unit; `MemoryHigh=` is recommended as the main control (`man systemd.resource-control`). What happens to the rest of the unit after an OOM kill is `OOMPolicy=` (`man systemd.scope`, `systemd.service`): `continue` (only logged), `stop` (the manager stops the whole unit cleanly) or `kill` (the kernel kills every process of the unit, `memory.oom.group=1`). The default comes from `DefaultOOMPolicy=` in `systemd-system.conf`, which is `stop`.

**Command** (node, root; creates a transient cgroup that disappears when the command ends). Python allocates 300 MB under a 100 MB limit; the wrapping shell then reads its own cgroup's `memory.events` while the scope still exists:

```bash
sudo systemd-run --scope --expand-environment=no -p MemoryMax=100M -p MemorySwapMax=0 -p OOMPolicy=continue sh -c 'python3 -I -c "b=b\"x\"*(300*1024*1024); print(\"allocated\")"; echo "exit=$?"; cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.events'
```

`--expand-environment=no`: the shell command contains `$`. With `--scope`, systemd-run 255 does not expand variables by default yet, but warns that the default will change; the option passes the argument verbatim, as documented in `man systemd-run`.

**Result:**

```
Running as unit: run-<id>.scope; invocation ID: <id>
Killed
exit=137
low 0
high 0
max 36
oom 1
oom_kill 1
oom_group_kill 0
sock_throttled 0
```

- `exit=137` = 128 + 9: Python was killed with SIGKILL by the kernel's OOM killer; `allocated` is never printed.
- `max 36`: usage hit the limit 36 times before the kill; `oom 1`, `oom_kill 1`: one OOM event, one process killed.
- `oom_group_kill 0`: with `continue` the kernel kills only the offending process; the shell survives and prints the counters.

**With the default policy** (`stop`, the same command without `-p OOMPolicy=continue`) the output is only `Terminated`: the shell never reaches `echo`. The journal shows why:

```bash
journalctl -b --no-pager -u run-<id>.scope
```

```
systemd[1]: run-<id>.scope: A process of this unit has been killed by the OOM killer.
systemd[1]: run-<id>.scope: Failed with result 'oom-kill'.
```

The kernel killed Python; then systemd stopped the whole unit and sent SIGTERM to the shell. The same applies to services: with a `MemoryMax=` and the default policy, one OOM-killed process stops the whole service, and only a `Restart=` setting brings it back.

## Step 7/19 — Ollama's memory with a model loaded (VRAM vs RAM)

**Why:** before a `MemoryMax=` goes on Ollama, measure what its cgroup counts while a model is loaded. The weights live in VRAM, but they are read from disk first, and the page cache of a file read by a process is charged to that process's cgroup. Too low a limit could force reclaim, or (for memory that cannot be reclaimed) an OOM kill; with the default `OOMPolicy=stop` (step 6) that stops the whole service.

Two cases: a model that fits on one card (`llama3.1:8b`, 4.9 GB on disk) and a model that does not (`qwen3.8:27b`, 17 GB on disk, on a 16 GB card).

**Command** (node, no root; loads a model for 10 minutes, nothing else changes). An empty `generate` request loads the model without generating; the cgroup files are world-readable:

```bash
curl -s localhost:11434/api/generate -d '{"model":"llama3.1:8b","keep_alive":"10m"}'; echo; ollama ps
cg=/sys/fs/cgroup/system.slice/ollama.service; echo "memory.current=$(cat $cg/memory.current)"; grep -E '^(anon|file|file_mapped|shmem|kernel) ' $cg/memory.stat
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
```

**Result (`llama3.1:8b`, 2026-10-15):**

```
NAME           ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.1:8b    46e0c10c039e    9.2 GB    100% GPU     32768      9 minutes from now
memory.current=6233808896
anon 549720064
file 5669257216
kernel 11747328
shmem 113274880
file_mapped 549703680
index, memory.used [MiB], memory.total [MiB]
0, 8936 MiB, 16311 MiB
1, 2 MiB, 16311 MiB
```

- The cgroup grows from ≈ 550 MiB (idle) to ≈ 5.8 GiB. About 5.3 GiB of it is `file`: page cache of the files Ollama read, mostly the model. `file_mapped` is only ≈ 524 MiB, so the weights are not kept mapped: they are read and copied into VRAM.
- `anon` (≈ 524 MiB) and `shmem` (≈ 108 MiB) are what the kernel cannot simply drop: it can only move them to swap (this host has 8 GiB, step 18). With the model fully on the GPU, that is ≈ 0.6 GiB.
- VRAM: 8.7 GiB on one card. The default context is 32768 tokens; the KV cache of Llama-3.1-8B is 128 KiB per token (roadmap, Lab 5), so 4 GiB for the context on top of ≈ 4.6 GiB of weights. `SIZE 9.2 GB` in `ollama ps` is weights plus KV cache.

**Second case** (the first model is unloaded with `keep_alive: 0`, then the larger one is loaded; same readings):

```bash
curl -s localhost:11434/api/generate -d '{"model":"llama3.1:8b","keep_alive":0}' >/dev/null; sleep 3
curl -s localhost:11434/api/generate -d '{"model":"qwen3.8:27b","keep_alive":"10m"}'; echo; ollama ps
```

**Result (`qwen3.8:27b`, 2026-10-15):**

```
NAME           ID              SIZE     PROCESSOR    CONTEXT    UNTIL
qwen3.8:27b    aaee06c39dcf    19 GB    100% GPU     32768      9 minutes from now
memory.current=24814649344
anon 745152512
file 24044597248
kernel 21659648
shmem 711041024
file_mapped 1574436864
index, memory.used [MiB], memory.total [MiB]
0, 10542 MiB, 16311 MiB
1, 11008 MiB, 16311 MiB
```

- A 17 GB model does not fit on one 16 GB card with its KV cache; Ollama splits it across both cards (≈ 21 GiB VRAM together) and still runs it 100% on the GPU.
- `file` ≈ 22.4 GiB: the page cache of **both** models. Unloading a model frees its VRAM, not the page cache of its file, and that cache stays charged to Ollama's cgroup until the kernel needs the memory. With every model loaded, `memory.current` grows towards the size of all model files read since the start, up to the host's RAM.
- `anon` + `shmem` ≈ 1.4 GiB: what Ollama itself needs while the model is fully on the GPUs.

**Third case: a model that does not fit into VRAM.** The server has two 16 GB cards, and none of the local models is larger than both together. For this test Ollama was temporarily limited to one card, so that `qwen3.8:27b` does not fit into VRAM; both cards were restored after the step.

**Measure** (node, root: the runner runs as `ollama`). The page cache of the host is dropped first (`drop_caches=1` drops only clean pages; nothing is lost, reads are slower for a while), so that Ollama is the first to read the model file:

```bash
sync; echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
curl -s localhost:11434/api/generate -d '{"model":"qwen3.8:27b","keep_alive":"10m"}'; echo; ollama ps
cg=/sys/fs/cgroup/system.slice/ollama.service; echo "memory.current=$(cat $cg/memory.current)"; grep -E '^(anon|file|file_mapped|shmem) ' $cg/memory.stat
sudo sh -c 'for p in $(cat /sys/fs/cgroup/system.slice/ollama.service/cgroup.procs); do echo "== pid=$p $(tr "\0" " " < /proc/$p/cmdline | cut -c1-60)"; grep -E "^(Rss|Pss_Anon|Pss_File)" /proc/$p/smaps_rollup; done'
nvidia-smi --query-gpu=index,memory.used --format=csv
```

`cgroup.procs` lists the processes of the service; `smaps_rollup` splits a process's resident memory into anonymous memory and file pages mapped into it.

**Result (2026-10-15):**

```
NAME           ID              SIZE     PROCESSOR          CONTEXT    UNTIL
qwen3.8:27b    aaee06c39dcf    18 GB    25%/75% CPU/GPU    4096       9 minutes from now
memory.current=18897199104
anon 703610880
file 18170781696
shmem 161931264
file_mapped 4537704448
== pid=… /usr/local/bin/ollama serve
Rss:               57772 kB
Pss_Anon:          32452 kB
Pss_File:          22312 kB
== pid=… /usr/local/lib/ollama/llama-server --model /usr/share/ollama
Rss:             5144964 kB
Pss_Anon:         654668 kB
Pss_File:        4328395 kB
index, memory.used [MiB]
0, 14324 MiB
1, 2 MiB
```

- A quarter of the model runs on the CPU. The model runs in a separate process, `llama-server` from llama.cpp, shipped with Ollama under `/usr/local/lib/ollama/`; models live under `/usr/share/ollama/.ollama/models` (needed for `ProtectSystem=strict`, step 10).
- The layers on the CPU are **mapped from the model file**: `Pss_File` ≈ 4.1 GiB in `llama-server`, `file_mapped` ≈ 4.2 GiB in the cgroup. Anonymous memory stays small (≈ 0.65 GiB). These are clean file pages: under memory pressure the kernel can drop them and read them again from disk, so a limit should make inference slow rather than kill the process (step 12).
- The context is 4096 tokens, not 32768: with `OLLAMA_CONTEXT_LENGTH` unset, Ollama picks the default by total VRAM (`docs/context-length.mdx`, `v0.32.14`: below 24 GiB 4k, 24–48 GiB 32k, 48 GiB and more 256k). One card is below 24 GiB; two are not.

**The same with a 32768-token context.** The context is set per request with the `num_ctx` option (`docs/modelfile.mdx`); nothing in the model or the service changes. Same commands, with the model unloaded and the cache dropped first, and this load request:

```bash
curl -s localhost:11434/api/generate \
  -d '{"model":"qwen3.8:27b","keep_alive":"10m","options":{"num_ctx":32768}}'
```

**Result:**

```
NAME           ID              SIZE     PROCESSOR          CONTEXT    UNTIL
qwen3.8:27b    aaee06c39dcf    18 GB    35%/65% CPU/GPU    32768      9 minutes from now
memory.current=19649191936
anon 1392820224
file 18229063680
shmem 220651520
file_mapped 5939265536
== pid=… /usr/local/lib/ollama/llama-server --model /usr/share/ollama
Rss:             7185052 kB
Pss_Anon:        1326128 kB
Pss_File:        5639691 kB
```

The bigger KV cache pushes more layers out of VRAM (35% on the CPU instead of 25%; `file_mapped` 5.5 GiB instead of 4.2), and `anon` grows by 0.63 GiB. llama.cpp logs its buffer sizes at load time:

```bash
journalctl -u ollama -n 300 --no-pager \
  | grep -E 'KV buffer size|compute buffer size|model buffer size' \
  | tail -n 12
```

```
load_tensors:        CUDA0 model buffer size = 10665.58 MiB
llama_kv_cache:        CPU KV buffer size =   640.00 MiB
llama_kv_cache:      CUDA0 KV buffer size =  1408.00 MiB
sched_reserve:      CUDA0 compute buffer size =   251.75 MiB
sched_reserve:  CUDA_Host compute buffer size =   142.59 MiB
```

The growth of `anon` is the **KV cache of the layers on the CPU**: 640 MiB. The whole KV cache is 2048 MiB for 32768 tokens (64 KiB per token for this model), split between CPU and GPU in about the same proportion as the layers.

**What follows for a memory limit:**

- `memory.current` is not Ollama's need. Most of it is page cache: of the model files read since the start, including models already unloaded. The kernel can drop it under a limit; the price is a slower next load.
- Layers that do not fit into VRAM are file pages mapped from the model, not anonymous memory. A limit below the model's CPU share makes the kernel re-read them from disk during inference: very slow, but not an OOM kill (tested with a real limit in step 12).
- The KV cache of layers on the CPU is anonymous memory and grows linearly with the context. This is the part that a limit can turn into an OOM kill, and only when a model does not fit into VRAM.
- What cannot be dropped as cache (`anon` + `shmem`; it can only go to swap) is 0.6–1.6 GiB in every case measured.

**Decision: a memory limit for Ollama.** `man systemd.resource-control` (systemd 255): `MemoryHigh=` is "the main mechanism to control memory usage of a unit": above it the processes are slowed down and memory is taken away aggressively, but not killed. `MemoryMax=` is the last line of defense: the OOM killer.

| Option | Directives | Against |
|---|---|---|
| A | `MemoryHigh=16G` only | No hard ceiling for the host |
| **B (chosen)** | `MemoryHigh=16G` + `MemoryMax=32G` | At the ceiling an OOM kill, and with the default `OOMPolicy=stop` the whole service stops |
| C | `MemoryMax=24G` only | No soft level: cache is dropped only at the ceiling, then the OOM killer |
| D | no limit | No protection for the rest of the host |

- `MemoryHigh=16G` is about ten times what Ollama cannot give back (up to 1.6 GiB measured), and below the page cache it accumulates when models are switched (22 GiB measured): the cache is reclaimed above it.
- `MemoryMax=32G` keeps at least half of the host's 64 GB for everything else. It can only be reached by memory that cannot be dropped as cache, such as the KV cache of CPU layers with a very large context; then an OOM kill of the runner is better than the kernel killing something else on the host. `MemoryMax=` limits RAM only: with swap on the host, the rest would go to swap unless `MemorySwapMax=0` is set too (step 18).
- What happens when a limit is reached (`OOMPolicy=`, `Restart=`) is decided in step 9; the limits are tested in step 12.

## Step 8/19 — Design decisions

**Why:** settle where the configuration lives before writing a role.

**How Ollama's installer treats the unit** (`scripts/install.sh`, tag `v0.32.14`, read through the GitHub API): on every run it rewrites `/etc/systemd/system/ollama.service` unconditionally (`tee`), runs `daemon-reload`, `enable` and `restart`; it never touches `ollama.service.d/`. It also creates the system user `ollama` with home `/usr/share/ollama` (where the models live) and adds it to the groups `render` and `video`.

**8a. Ollama: drop-in or own unit.**

| Option | For | Against |
|---|---|---|
| **A (chosen):** drop-ins in `ollama.service.d/`, deployed by the role | Survive upgrades (the installer does not touch `.d/`); a clear line between Ollama's unit and ours | Depend on the base unit; a new `ExecStart` from an upgrade is not seen by the drop-in |
| B: own `ollama.service` from the role | The whole unit in git | Every upgrade overwrites it; until the role runs again Ollama runs without restrictions |

The existing `override.conf` (listen address, GPU wait) moves into the role with the same settings (its comments rewritten); hardening and limits go into a separate drop-in.

**8b. The demo service's secret.** The secret never enters git.

| Option | For | Against |
|---|---|---|
| **A (chosen):** `EnvironmentFile=`, root:root `0600`, created by hand; the role only checks that it exists with the right mode | No new tool; exactly the roadmap's topic | A manual step on a new host; the secret is in the process environment (readable by root and the same user through `/proc/<pid>/environ`) |
| B: the same, content from Ansible Vault | Fully automated | Vault is planned for Lab 1; a vault password on two control points, and `--diff` prints the secret unless the task has `no_log`/`diff: false` |
| C: `LoadCredential=` | The secret is a file only the service can read, not an environment variable | Not the roadmap's topic; shown as a comparison only |

**8c. Roles and playbooks.**

| Option | For | Against |
|---|---|---|
| **A (chosen):** role `ollama` (permanent, playbook `ollama.yml`) and role `lab0b_demo` (lab only, playbook `lab0b.yml`), both imported by `site.yml` | Different lifecycles: Ollama stays, the demo can be removed; the same split as `claude_code` vs `lab_tools` | Two roles for one lab |
| B: one role `systemd_services` | Fewer files | Mixes permanent and temporary configuration |

## Step 9/19 — Role `ollama`: restart policy, start limit, OOM policy, base sandboxing

**Why:** put Ollama's systemd configuration into git, and add the first, cheapest directives.

**Documentation** (systemd 255):

- `Restart=` (`man systemd.service`): `on-failure` restarts after a non-zero exit code, a signal other than the four "clean" ones (SIGHUP, SIGINT, SIGTERM, SIGPIPE), a timeout or a watchdog; `always` also after a clean exit. A stop by systemd itself (`systemctl stop`, `restart`) never triggers a restart. The table of exit causes does not list an OOM kill; how `OOMPolicy=` and `Restart=` interact is tested in step 18.
- `StartLimitIntervalSec=`, `StartLimitBurst=` (`man systemd.unit`, section `[Unit]`): more than *burst* starts within *interval* and the unit is not started again; `Restart=` stops trying, the unit stays `failed` until it is started by hand after the interval or `systemctl reset-failed` clears the counter. All starts count, manual ones too. The defaults (`man systemd-system.conf`) are 5 starts in 10 s; with `RestartSec=3` Ollama starts at most 4 times in 10 s, so the default never triggers and a permanently broken Ollama would restart forever.
- `RestartSteps=`, `RestartMaxDelaySec=` (since 254): a growing delay between restarts instead of a limit.
- `NoNewPrivileges=` (`man systemd.exec`): the process and its children can never gain privileges through `execve()` (setuid/setgid bits, file capabilities).
- `PrivateTmp=`: private `/tmp` and `/var/tmp`, removed when the service stops.
- The `+` prefix of `ExecStartPre=` (`man systemd.service`): that command runs with full privileges; `User=`, `CapabilityBoundingSet=` and the namespacing options (`PrivateDevices=`, `PrivateTmp=`) do not apply to it, but options that apply to the whole control group, such as `DevicePolicy=`, still do (step 11).

**Decisions:**

| Setting | Options | Chosen | Why |
|---|---|---|---|
| `Restart=` | `always` (installer), `on-failure` | `on-failure` | A clean exit is deliberate; a crash is not |
| `OOMPolicy=` | `stop` (default), `continue`, `kill` | `continue` | The OOM victim is normally the model runner (`llama-server`, which holds the memory); the server stays up and can start a new runner (tested in step 18). With `stop` every client loses the service |
| Restart loop | start limit; growing delay (`RestartSteps=`); both | start limit: 5 starts in 5 minutes | A finite number of attempts and a clear `failed` state. Both together are hard to reason about: growing delays move the attempts out of the window. Nothing alerts on `failed` yet (Lab 2) |

**Files** (`<repo>/ansible`):

- `ollama.yml`: `hosts: z790`, `become: true`, role `ollama`; imported at the end of `site.yml`.
- `roles/ollama/files/override.conf`: the existing drop-in, same settings, comments rewritten.
- `roles/ollama/files/hardening.conf`:

  ```ini
  [Unit]
  StartLimitIntervalSec=5min
  StartLimitBurst=5

  [Service]
  Restart=on-failure
  OOMPolicy=continue
  NoNewPrivileges=yes
  PrivateTmp=yes
  ```

  `Restart=` in a drop-in replaces the base unit's value. Drop-ins are read in alphabetical order; the two files set different keys.
- `roles/ollama/tasks/main.yml`: the directory `ollama.service.d` (`0755`), both drop-ins (`0644`, `notify: Restart Ollama`), and the service `enabled` + `started`.
- `roles/ollama/handlers/main.yml`: `ansible.builtin.systemd_service` with `daemon_reload: true`, `state: restarted`. Unit settings take effect only after a reload and a restart; the restart makes Ollama unavailable for a few seconds and unloads every model, so the role restarts it only when a drop-in changes.
- `roles/ollama/README.md`.

**Command** (node in `<repo>/ansible`, then the control node after `git pull --ff-only`; then from the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Result:**

- Lint on both control points: `Passed: 0 failure(s), 0 warning(s) in 20 files processed of 34 encountered`, profile `production`.
- Check mode: `override.conf` `changed` with a diff of comments only, `hardening.conf` `changed` with a diff from nothing, the service `ok`, the handler `changed` (reported, not run). Recap `ok=23 changed=2 skipped=2 failed=0`.
- Real run: the same, and the handler restarts Ollama. Recap `ok=23 changed=2 skipped=2 failed=0`.

**Verify the running state** (node, no root): the files say what was written, `systemctl show` what systemd loaded.

```bash
systemctl show ollama -p ActiveState,NRestarts,DropInPaths
systemctl show ollama -p Restart,OOMPolicy,NoNewPrivileges,PrivateTmp
systemctl show ollama -p StartLimitIntervalUSec,StartLimitBurst
journalctl -u ollama -n 40 --no-pager | grep 'inference compute'
systemd-analyze security ollama.service --no-pager | tail -n 1
```

**Result:**

```
ActiveState=active
NRestarts=0
DropInPaths=/etc/systemd/system/ollama.service.d/hardening.conf /etc/systemd/system/ollama.service.d/override.conf
Restart=on-failure
OOMPolicy=continue
NoNewPrivileges=yes
PrivateTmp=yes
StartLimitIntervalUSec=5min
StartLimitBurst=5
msg="inference compute" id=0 … library=CUDA … name=CUDA0 … pci_id=0000:01:00.0 …
msg="inference compute" id=1 … library=CUDA … name=CUDA1 … pci_id=0000:02:00.0 …
→ Overall exposure level for ollama.service: 8.7 EXPOSED 🙁
```

Both cards are found after the restart (the GPU wait works), and the score drops from 9.2 UNSAFE to 8.7 EXPOSED.

## Step 10/19 — `ProtectSystem=strict` and the paths Ollama writes

**Why:** with `ProtectSystem=strict` the whole file system is read-only for the service; every path it must write has to be listed. Finding those paths is the work.

**Documentation** (`man systemd.exec`, systemd 255):

- `ProtectSystem=`: `yes` makes `/usr` and the boot loader directories read-only, `full` adds `/etc`, `strict` the entire hierarchy except the API file systems `/dev`, `/proc` and `/sys` (protected by other directives).
- `ReadWritePaths=`: paths that stay writable inside the read-only hierarchy (a read-only file system stays read-only). A `-` prefix skips a path that does not exist.
- `ProtectHome=`: `yes` makes `/home`, `/root` and `/run/user` empty and inaccessible; `read-only` and `tmpfs` are milder.

**Where Ollama writes** (node, read-only):

```bash
ls -la /usr/share/ollama /usr/share/ollama/.ollama; du -sh /usr/share/ollama/.ollama/models
```

Ollama's home is `/usr/share/ollama` (created by the installer, step 8), **under `/usr`**: even the mildest `ProtectSystem=yes` would make it read-only. Inside: `.ollama/models` (the models, 85 GB here; written by `pull`, `cp`, `rm`, `create`), `.ollama/cache` (changed at every start), `.ollama/id_ed25519` (Ollama's key for ollama.com, created once), and `.nv` (NVIDIA's cache of compiled CUDA kernels).

**Decision:**

| Option | `ReadWritePaths=` | For | Against |
|---|---|---|---|
| A | `/usr/share/ollama` | Nothing can be missed | Shell start-up files in the home become writable too |
| **B (chosen)** | `/usr/share/ollama/.ollama` and `-/usr/share/ollama/.nv` | Only what Ollama writes; `-` keeps a host without `.nv` starting | A future version writing elsewhere fails; the test has to catch it |
| C | Move the models to `/var/lib/ollama` (`OLLAMA_MODELS`) | The usual place for a service's data | Moves 85 GB; out of scope |

Plus `ProtectHome=yes`: Ollama has no business in `/home`.

**Added to `roles/ollama/files/hardening.conf`:**

```ini
ProtectSystem=strict
ReadWritePaths=/usr/share/ollama/.ollama -/usr/share/ollama/.nv
ProtectHome=yes
```

**Command** (control node; root on the node through become):

```bash
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Result:** `hardening.conf` `changed` with the three directives (and their comment) in the diff, the handler restarts Ollama; recap `ok=23 changed=2 skipped=2 failed=0` in both runs.

**Verify the running state and the score** (node, no root):

```bash
systemctl show ollama -p ActiveState,NRestarts,ExecMainStartTimestamp
systemctl show ollama -p ProtectSystem,ProtectHome,ReadWritePaths
journalctl -u ollama -n 40 --no-pager | grep 'inference compute'
journalctl -u ollama -n 200 --no-pager | grep -iE 'read-only|permission denied'
systemd-analyze security ollama.service --no-pager | tail -n 1
```

**Result:** active, started by the handler, `ProtectSystem=strict`, `ProtectHome=yes`, both paths; both cards found after the restart; no write errors; **8.3 EXPOSED** (from 8.7).

**Test the effect** (node, no root; nothing is downloaded): copying a model writes a manifest under `models/`, deleting it removes it; a short generation loads a model.

```bash
ollama cp llama3.1:8b lab0b-rw-test
ollama list | grep lab0b-rw-test
ollama rm lab0b-rw-test
ollama run llama3.1:8b 'Say OK.' --keepalive 1m
ollama ps
journalctl -u ollama --since '-5min' --no-pager \
  | grep -iE 'read-only|permission denied|error' || echo "(no errors)"
```

**Result:**

```
copied 'llama3.1:8b' to 'lab0b-rw-test'
lab0b-rw-test:latest                  46e0c10c039e    4.9 GB    Less than a second ago
deleted 'lab0b-rw-test'
OK.
NAME           ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.1:8b    46e0c10c039e    9.2 GB    100% GPU     32768      59 seconds from now
(no errors)
```

## Step 11/19 — GPU access under device restrictions

**Why:** device access is where hardening can break Ollama silently: without its devices it does not fail, it starts after the 60-second GPU wait and runs on the CPU.

**Documentation** (systemd 255):

- `PrivateDevices=yes` (`man systemd.exec`): a new `/dev` with only pseudo devices (`null`, `zero`, `random`, TTYs), no physical devices; it also sets `DevicePolicy=closed`, removes `CAP_SYS_RAWIO` and `CAP_MKNOD` and blocks the `@raw-io` system calls. `/dev/nvidia*` would disappear for Ollama.
- `DevicePolicy=` (`man systemd.resource-control`): `strict` allows only what `DeviceAllow=` lists, `closed` also the standard pseudo devices, `auto` (default) everything when no `DeviceAllow=` is set. It applies to the whole control group and **cannot be bypassed with the `+` prefix**: it covers the GPU wait in `ExecStartPre=+` too.
- `DeviceAllow=`: a device path, or a device group from `/proc/devices` as `char-<name>` (all current and future devices of that group), with `r`, `w`, `m`. Enforced with eBPF. A group that does not exist when the unit starts is silently dropped; the page suggests `Wants=`/`After=modprobe@<module>.service`.

**What the host has and what Ollama opens** (node; the last command needs root: the runner runs as `ollama`). With `llama3.1:8b` loaded:

```bash
ls -l /dev/nvidia* /dev/dri/ /dev/nvidia-caps/
grep -iE 'nvidia|drm' /proc/devices
cg=/sys/fs/cgroup/system.slice/ollama.service
sudo sh -c "for p in \$(cat $cg/cgroup.procs); do
  echo \"== \$p \$(cat /proc/\$p/comm)\"
  ls -l /proc/\$p/fd | grep -o '/dev/.*' | sort | uniq -c; done"
```

**Result:** the host has `/dev/nvidia0`, `nvidia1`, `nvidiactl`, `nvidia-modeset` (group `nvidia`, major 195), `nvidia-uvm`, `nvidia-uvm-tools` (group `nvidia-uvm`, 510), `nvidia-caps/nvidia-cap1`, `cap2` (235) and `/dev/dri/card0`, `card1`, `renderD128`, `renderD129` (`drm`, 226; groups `video` and `render`, of which `ollama` is a member). Open file descriptors:

```
== … ollama
      1 /dev/null
== … llama-server
      1 /dev/null
     18 /dev/nvidia0
      1 /dev/nvidiactl
      2 /dev/nvidia-uvm
```

The model fits on GPU0, so only `nvidia0` is open; a model spread over both cards opens `nvidia1` too, and so does device discovery at start. Nothing under `/dev/dri`, no `nvidia-caps`, no `nvidia-modeset`.

**When `nvidia_uvm` is loaded** (node, read-only):

```bash
grep -E '^nvidia' /proc/modules | cut -d' ' -f1
cat /usr/lib/udev/rules.d/71-nvidia.rules
```

udev loads `nvidia-modeset`, `nvidia-drm` and `nvidia-uvm` when the `nvidia` driver binds at boot, and creates the device nodes. `nvidia-modprobe` (setuid, which `NoNewPrivileges=` would block) is not installed. `DeviceAllow=` groups are resolved when the unit starts, **before** `ExecStartPre=`, so the GPU wait does not help; `modprobe@nvidia_uvm.service` (`modprobe -abq nvidia_uvm`, which also loads `nvidia`) does.

**Decision:**

| Option | Directives | For | Against |
|---|---|---|---|
| **A (chosen):** device groups | `DevicePolicy=closed`, `DeviceAllow=char-nvidia rw`, `DeviceAllow=char-nvidia-uvm rw`, `Wants=`/`After=modprobe@nvidia_uvm.service` | Independent of the number of cards (one card is planned to move to another node); covers future devices of the driver | Group `nvidia` (major 195) also includes `nvidia-modeset`, which Ollama does not use |
| B: exact paths | `/dev/nvidia0`, `/dev/nvidia1`, `/dev/nvidiactl`, `/dev/nvidia-uvm` | Exactly what was seen open | Breaks when the number of cards changes |
| C: `PrivateDevices=yes` + `BindPaths=` of `/dev/nvidia*` | Passes the `PrivateDevices=` check of the score | The private `/dev` is `noexec` and CUDA maps these devices; complex and fragile |

**Added to `roles/ollama/files/hardening.conf`:**

```ini
[Unit]
Wants=modprobe@nvidia_uvm.service
After=modprobe@nvidia_uvm.service

[Service]
DevicePolicy=closed
DeviceAllow=char-nvidia rw
DeviceAllow=char-nvidia-uvm rw
```

**Command** (control node): `--check --diff`, then the real run. **Result:** `hardening.conf` `changed`, recap `ok=23 changed=2 skipped=2 failed=0`.

**Verify immediately** (node, no root): Ollama must find both cards through CUDA, and within seconds of the start (a 60-second gap means the GPU wait failed).

```bash
systemctl show ollama -p ActiveState,ExecMainStartTimestamp
systemctl show ollama -p DevicePolicy,DeviceAllow
journalctl -u ollama -n 40 --no-pager | grep 'inference compute'
```

**Result:** active since 12:17:12, `DevicePolicy=closed`, both `DeviceAllow=` entries; `inference compute` for `CUDA0` and `CUDA1` at 12:17:15.

**Test with a model on both cards** (node, no root):

```bash
ollama run qwen3.8:27b 'Say OK.' --keepalive 2m
ollama ps
nvidia-smi --query-gpu=index,memory.used --format=csv
journalctl -u ollama --since '-3min' --no-pager \
  | grep -iE 'permission denied|not permitted|error' || echo "(no errors)"
```

**Result:** `OK.`; `qwen3.8:27b  19 GB  100% GPU  32768`; 10554 / 11016 MiB; `(no errors)`.

**Negative test:** "it works" could also mean "nothing is restricted". The same rules in a transient service as user `ollama`, then without them as a control (node, root; both services disappear when they end). `ollama` is in the `render` group and `nvidia-cap2` is world-readable, so file permissions allow both; only the device rules can refuse them. Each attempt runs in a subshell: a failed redirection on the special built-in `:` would end a non-interactive `sh`.

```bash
t='for d in /dev/nvidiactl /dev/nvidia-uvm /dev/dri/renderD128 /dev/nvidia-caps/nvidia-cap2; do ( : < $d ) && echo "$d: opened"; done'
sudo systemd-run --wait --pipe --quiet --expand-environment=no \
  -p User=ollama -p DevicePolicy=closed \
  -p DeviceAllow='char-nvidia rw' -p DeviceAllow='char-nvidia-uvm rw' \
  sh -c "$t"
sudo systemd-run --wait --pipe --quiet --expand-environment=no \
  -p User=ollama sh -c "$t"
```

**Result:**

```
/dev/nvidiactl: opened
/dev/nvidia-uvm: opened
/usr/bin/sh: 1: cannot open /dev/dri/renderD128: Operation not permitted
/usr/bin/sh: 1: cannot open /dev/nvidia-caps/nvidia-cap2: Operation not permitted
```

and without the rules all four `opened`.

**Score** (node, no root):

```bash
systemd-analyze security ollama.service --no-pager \
  | grep -E 'PrivateDevices=|DeviceAllow=|Overall'
```

```
✗ PrivateDevices=   Service potentially has access to hardware devices                                     0.2
✗ DeviceAllow=      Service has a device ACL with some special devices: char-nvidia-uvm:rw char-nvidia:rw  0.1
→ Overall exposure level for ollama.service: 8.2 EXPOSED 🙁
```

A device list with real hardware in it earns half of the check (0.1 of 0.2); `PrivateDevices=` stays failed on purpose. 8.3 → 8.2.

## Step 12/19 — Resource limits: memory, CPU, tasks

**Why:** the memory limit was decided from measurements in step 7; CPU and task limits need the same: what does Ollama use at its worst?

**Documentation** (`man systemd.resource-control`, systemd 255): `CPUQuota=` is a percentage of **one** CPU (`cpu.max`); values above 100% allow more than one CPU. `TasksMax=` caps processes and threads in the unit (`pids.max`); the default comes from `DefaultTasksMax=` (here 70833, Lab 0a).

**Measure the worst case for CPU and tasks** (node, no root): a model entirely on the CPU. Ollama's API takes `num_gpu` (layers on the GPU) as a request option (`docs/api.md`); `0` keeps everything on the CPU. CPU time comes from the cgroup's `cpu.stat`, the task peak from `pids.peak`.

```bash
cg=/sys/fs/cgroup/system.slice/ollama.service
o='"options":{"num_gpu":0}'
curl -s localhost:11434/api/generate \
  -d "{\"model\":\"llama3.1:8b\",\"keep_alive\":\"5m\",$o}" >/dev/null
ollama ps
u0=$(awk '/usage_usec/{print $2}' $cg/cpu.stat); t0=$(date +%s%N)
curl -s localhost:11434/api/generate \
  -d "{\"model\":\"llama3.1:8b\",\"prompt\":\"Write 150 words about systemd.\",\"stream\":false,\"options\":{\"num_gpu\":0,\"num_predict\":150}}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tokens", d["eval_count"], "tok/s", round(d["eval_count"]/d["eval_duration"]*1e9,1))'
u1=$(awk '/usage_usec/{print $2}' $cg/cpu.stat); t1=$(date +%s%N)
echo "cpu% = $(( (u1-u0)*1000*100 / (t1-t0) ))"
echo "pids.current=$(cat $cg/pids.current) pids.peak=$(cat $cg/pids.peak)"
journalctl -u ollama -n 400 --no-pager | grep -oE 'n_threads[ =]+[0-9]+' | sort | uniq -c
```

**Result (2026-10-15):**

```
NAME           ID              SIZE      PROCESSOR    CONTEXT    UNTIL
llama3.1:8b    46e0c10c039e    9.5 GB    100% CPU     32768      4 minutes from now
tokens 150 tok/s 13.6
cpu% = 789
pids.current=58 pids.peak=76
      3 n_threads = 8
```

One runner on the CPU uses 8 threads (llama.cpp's `n_threads = 8`, about 790% of one CPU out of 28) and generates 13.6 tokens/s. The service has 21 tasks idle and peaks at 76 with one runner.

**Decisions:**

| Setting | Options | Chosen | Why |
|---|---|---|---|
| `CPUQuota=` | none; `1600%`; `800%`; `CPUWeight=` (priority only) | `1600%` | Two runners on the CPU run unthrottled; at least 12 CPUs always stay for the host. `800%` would throttle every burst above one runner; `CPUWeight=` sets no ceiling |
| `TasksMax=` | 70833 (default); `512`; `128` | `512` | About nine runners at once; `128` would leave room for about two, and a third model could fail to start with an unclear error |
| Memory | step 7 | `MemoryHigh=16G`, `MemoryMax=32G` | |

**Added to `roles/ollama/files/hardening.conf`:**

```ini
MemoryHigh=16G
MemoryMax=32G
CPUQuota=1600%
TasksMax=512
```

**Command** (control node): `--check --diff`, then the real run. **Result:** `hardening.conf` `changed` with the four limits, recap `ok=23 changed=2 skipped=2 failed=0`.

**Verify the running state** (node, no root):

```bash
systemctl show ollama -p ActiveState,ExecMainStartTimestamp
systemctl show ollama -p MemoryHigh,MemoryMax,CPUQuotaPerSecUSec,TasksMax
journalctl -u ollama -n 40 --no-pager | grep -c 'inference compute'
```

**Result:** active, restarted by the handler; `MemoryHigh=17179869184` (16 GiB), `MemoryMax=34359738368` (32 GiB), `CPUQuotaPerSecUSec=16s` (16 CPU-seconds per second = 1600%), `TasksMax=512`; both cards found.

**Test: `MemoryHigh` reclaims the page cache.** Loading two models in a row reads about 22 GiB of model files (step 7), more than `MemoryHigh`. The restart created a new cgroup, and model files already in the page cache would not be charged to it (step 7), so the cache is dropped first (node; `drop_caches` needs root):

```bash
cg=/sys/fs/cgroup/system.slice/ollama.service
sync; echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
curl -s localhost:11434/api/generate \
  -d '{"model":"llama3.1:8b","keep_alive":"10m"}' >/dev/null
echo "after llama: $(cat $cg/memory.current)"
curl -s localhost:11434/api/generate \
  -d '{"model":"qwen3.8:27b","keep_alive":"10m"}' >/dev/null
echo "after qwen:  $(cat $cg/memory.current)"
grep -E '^(anon|file) ' $cg/memory.stat
cat $cg/memory.events
ollama run qwen3.8:27b 'Say OK.' --keepalive 10m
ollama ps
```

**Result:**

```
after llama: 5593628672
after qwen:  17176473600
anon 528203776
file 16626864128
low 0
high 916
max 0
oom 0
oom_kill 0
oom_group_kill 0
sock_throttled 8
OK.
NAME           ID              SIZE     PROCESSOR    CONTEXT    UNTIL
qwen3.8:27b    aaee06c39dcf    19 GB    100% GPU     32768      9 minutes from now
```

- The cgroup stays 3.2 MiB below `MemoryHigh` (17179869184) instead of growing to 23 GiB: the kernel reclaimed page cache 916 times (`high`). `MemoryMax` was never reached (`max 0`), nothing was killed (`oom_kill 0`).
- The model works, entirely on the GPUs. Ollama unloaded `llama3.1:8b` to make room for it.

**Test: `CPUQuota` does not slow a runner on the CPU.** The measurement from above, with the quota in force, plus the cgroup's throttling counters:

```bash
grep -E '^(nr_throttled|throttled_usec)' $cg/cpu.stat
```

**Result:** `tokens 150 tok/s 13.2`, `cpu% = 783`, `nr_throttled 0`, `throttled_usec 0`: the same as without the quota (13.6 tokens/s, 789%), never throttled.

## Step 13/19 — Kernel, process and privilege restrictions

**Why:** the remaining failed checks of `systemd-analyze security` (step 4). Most of them are cheap for a service that runs as a plain user and needs no kernel access; a few can break a GPU service and are tried one by one in step 15.

**Documentation** (`man systemd.exec`, systemd 255), with the side effects that matter here:

- `ProtectKernelTunables=`: `/proc/sys`, `/sys`, `/proc/sysrq-trigger`, `/proc/acpi`, `/proc/fs`, `/proc/irq` and a few more become read-only. Reading stays possible.
- `ProtectKernelModules=`: no module loading (removes `CAP_SYS_MODULE`, filters the module system calls). `nvidia_uvm` is loaded before Ollama by `modprobe@` (step 11).
- `ProtectKernelLogs=`: no access to the kernel log ring buffer. `ProtectControlGroups=`: `/sys/fs/cgroup` read-only.
- `ProtectClock=`: no clock changes; it also implies `DeviceAllow=char-rtc r`, the only side effect on device access in this group.
- `ProtectHostname=`: own UTS namespace, host name cannot change.
- `ProtectProc=invisible`: processes of other users disappear from `/proc`; the page recommends it for most services. `ProcSubset=pid` hides everything in `/proc` that is not a process and is "not suitable for most non-trivial programs": the NVIDIA driver uses `/proc/driver/nvidia` (step 15).
- `PrivateMounts=`: own mount namespace. `CapabilityBoundingSet=` empty: no capabilities at all (`ExecStartPre=+` is not affected, step 9).
- `RestrictSUIDSGID=`, `RestrictRealtime=` (no `SCHED_FIFO`/`SCHED_RR`/`SCHED_DEADLINE`), `RestrictNamespaces=yes`, `LockPersonality=`, `SystemCallArchitectures=native`.
- `RemoveIPC=`: System V and POSIX IPC objects of the service user are removed when it stops. `UMask=`: the file mode creation mask (default `0022`).
- `MemoryDenyWriteExecute=` is incompatible with code generated at run time (JIT); whether CUDA compiles kernels for these cards at load time is a question for a test (step 15).

**Decision:** two groups. Group 1, expected to be safe, goes straight into the role and is tested afterwards (step 14): `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `PrivateMounts`, `CapabilityBoundingSet=` (empty), `RestrictSUIDSGID`, `RestrictRealtime`, `RestrictNamespaces=yes`, `LockPersonality`, `SystemCallArchitectures=native`, `RemoveIPC`, `UMask=0027` (files Ollama creates stay readable for the group `ollama`, not for everyone). Group 2, with a real risk for the GPU or CUDA, is tried one directive at a time with a temporary runtime drop-in before anything goes into the role (step 15): `RestrictAddressFamilies=`, `SystemCallFilter=`, `MemoryDenyWriteExecute=`, `PrivateUsers=`, `ProcSubset=pid`. Failed on purpose: `PrivateNetwork=` (Ollama serves clients), `IPAddressDeny=` (it downloads models), `PrivateDevices=` (step 11).

**Command** (control node): `--check --diff`, then the real run. **Result:** `hardening.conf` `changed` with group 1, recap `ok=23 changed=2 skipped=2 failed=0`.

**Verify** (node, no root):

```bash
systemctl show ollama -p ActiveState,ExecMainStartTimestamp
systemctl show ollama -p ProtectProc,CapabilityBoundingSet,RestrictNamespaces
journalctl -u ollama --since '<start time>' --no-pager \
  | grep -iE 'inference compute|no compatible|discover' | cut -c1-200
systemd-analyze security ollama.service --no-pager | tail -n 1
```

**Result:** active; `ProtectProc=invisible`, `CapabilityBoundingSet=` (empty), `RestrictNamespaces=yes`; `discovering available GPUs...`, then `inference compute` for `CUDA0` and `CUDA1`; **3.4 OK** 🙂 (from 8.2). Device discovery took 6 seconds after the start (3 seconds after step 11).

## Step 14/19 — Regression tests after hardening

**Why:** the checks so far cover the main path (both cards found, a model loaded, a reply generated). Ollama does more than that, and each part could be broken by a restriction without an error in the obvious places. The same tests run again after step 15.

All commands on the node, no root (Docker access for test 2). Each test ends with a look at the journal:

```bash
journalctl -u ollama --since '-3min' --no-pager \
  | grep -iE 'denied|not permitted|error|warn' | cut -c1-200
```

**1. Write path: copy, delete, pull; embeddings.** `pull` uses the network, writes large files and temporary files; `all-minilm` is a 45 MB embedding model.

```bash
ollama cp llama3.1:8b lab0b-rw-test
ollama rm lab0b-rw-test
ollama pull all-minilm
curl -s localhost:11434/api/embed \
  -d '{"model":"all-minilm","input":"systemd hardening"}' \
  | python3 -c 'import json,sys; e=json.load(sys.stdin)["embeddings"][0]; print("dims", len(e), "first", round(e[0],4))'
ollama ps
ollama rm all-minilm
```

Result: `copied`, `deleted`; `pull` ends with `verifying sha256 digest`, `writing manifest`, `success`; `dims 384`; `all-minilm` `100% GPU`; `deleted`; nothing in the journal.

**2. A client in a container.** Other clients on the server reach Ollama from Docker. A throwaway container on a user-defined Docker network (`host-gateway` resolves to the host):

```bash
docker run --rm --network <network> \
  --add-host=host.docker.internal:host-gateway \
  alpine:3.24 wget -qO- -T 5 http://host.docker.internal:11434/api/version
```

Result: `{"version":"0.32.14"}`. None of the directives restricts incoming connections; what reaches the port is the firewall's business (Lab 0c).

**3. Generation on both cards, and images.** `qwen3.8:27b` spans both cards and has a vision encoder. A small Python script (`work/lab0b/vision-test.py`, not in the repository: it builds a 64×64 red PNG in memory and sends it base64-encoded to `/api/generate` with the question "What colour is this image? Answer with one word.") checks the image path:

```bash
ollama run qwen3.8:27b 'Say OK.' --keepalive 2m
ollama ps
nvidia-smi --query-gpu=index,memory.used --format=csv
python3 <repo>/work/lab0b/vision-test.py
```

Result: `OK.`; `qwen3.8:27b  19 GB  100% GPU  32768`; 10554 / 11016 MiB; `Red`; the journal shows `clip_model_loader: … has vision encoder` and `CLIP using CUDA0 backend`, no errors.

**4. Speed.** The CPU measurement from step 12 (`llama3.1:8b` with `num_gpu: 0`, 150 tokens): `tok/s 13.4`, `cpu% = 784`, `nr_throttled 0`. Before this step: 13.2 tokens/s with the quota, 13.6 without.

**5. Boot.** A reboot tests the order `modprobe@nvidia_uvm` → device rules → GPU wait → discovery; it runs once at the end of the lab (step 19), after all changes.

## Step 15/19 — The risky directives, one at a time

**Why:** five directives can break a GPU service in ways that are not obvious (a process killed by a system call filter, CUDA without its devices or its executable memory, Ollama without system information). Each is tried on its own before it goes into the role.

**Method:** a temporary runtime drop-in under `/run/systemd/system/ollama.service.d/` (gone after a reboot, nothing in `/etc` changes). Each directive is added to the same file, so the last test covers the whole combination; then `daemon-reload`, a restart, and a test.

```bash
d=/run/systemd/system/ollama.service.d
sudo mkdir -p $d
printf '[Service]\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK\n' \
  | sudo tee $d/lab0b-trial.conf
printf 'SystemCallFilter=@system-service\n' | sudo tee -a $d/lab0b-trial.conf   # next directive, and so on
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

**Test after each directive** (node, no root): both cards found, a two-card model 100% on the GPU, an image, a model entirely on the CPU (other code paths: thread placement, system memory), a pull, a client in a container, and the journal (the three `no usable GPU found` lines are llama.cpp's normal note for a CPU-only runner and are filtered out):

```bash
journalctl -u ollama --since '-20s' --no-pager | grep -c 'inference compute'
ollama run qwen3.8:27b 'Say OK.' --keepalive 1m
ollama ps
nvidia-smi --query-gpu=index,memory.used --format=csv
python3 <repo>/work/lab0b/vision-test.py
curl -s localhost:11434/api/generate \
  -d '{"model":"llama3.1:8b","prompt":"Say OK.","stream":false,"options":{"num_gpu":0,"num_predict":20}}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("cpu run:", d["response"].strip()[:40])'
ollama pull all-minilm && ollama rm all-minilm
docker run --rm --network <network> \
  --add-host=host.docker.internal:host-gateway \
  alpine:3.24 wget -qO- -T 5 http://host.docker.internal:11434/api/version
journalctl -u ollama --since '-5min' --no-pager \
  | grep -iE 'denied|not permitted|operation not|error|warn|SIGSYS' \
  | grep -vE 'usable GPU|without GPU support|docs/build.md'
```

**1. `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`.** `man systemd.exec`: restricts `socket(2)` only (which sockets the process can create; accepted connections and `socketpair()` are not affected), should be combined with `SystemCallArchitectures=native`, does not apply to `+` commands. `AF_NETLINK` is for Go's network interface listing. **Result:** passes; pull (outgoing) and a container client (incoming) work.

**2. `SystemCallFilter=@system-service`, `SystemCallErrorNumber=EPERM`.** `man systemd.exec`: by default a system call outside the list **kills the process with `SIGSYS`**; `SystemCallErrorNumber=` makes it fail with an error instead. `systemd-analyze syscall-filter @system-service` lists the set: `@basic-io`, `@file-system`, `@network-io`, `@process`, `@ipc`, `@resources`, `@memlock` and 45 single calls including `ioctl` (how CUDA talks to the driver); `@privileged`, `@mount`, `@module`, `@raw-io`, `@reboot`, `@swap`, `@clock`, `@debug`, `@obsolete` are not in it.

| Option | On a missing system call | Against |
|---|---|---|
| A: `SystemCallFilter=` only | `SIGSYS`, the process dies | "killed by signal SYS" without the call's name; a restart loop up to the start limit |
| **B (chosen):** plus `SystemCallErrorNumber=EPERM` | the call returns `EPERM`, the program decides | A program may carry on with a feature missing; the journal check above looks for it |

**Result:** passes, `SystemCallErrorNumber=1` (EPERM).

**3. `PrivateUsers=yes`.** `man systemd.exec`: an own user namespace in which only `root` and the unit's user and group map to themselves, everyone else to `nobody`; no capabilities in the host's namespace. `ollama`'s supplementary groups `render` and `video` become `nobody` inside, but `/dev/nvidia*` are world-accessible (`crw-rw-rw-`) and `/dev/dri` is denied anyway. The namespace is created by systemd (root), so Ubuntu's restriction on unprivileged user namespaces (Lab 0f) does not apply. **Result:** passes; a pulled manifest is owned by `ollama` (`999:987`, not `65534`) with mode `-rw-r-----` (`UMask=0027`, step 13).

**4. `MemoryDenyWriteExecute=yes`.** No memory that is writable and executable, no memory turned executable later: no JIT. The risk is silent: if CUDA cannot load its kernels, Ollama may fall back to the CPU. **Result:** passes; `qwen3.8:27b` `100% GPU`, 10554 / 11016 MiB as before. CUDA in this Ollama version loads ready-made kernels for these cards; re-test after an upgrade.

**5. `ProcSubset=pid`.** Everything in `/proc` that is not a process disappears; the page calls it "not suitable for most non-trivial programs". **Result:** both cards are found and every test passes, but the journal shows:

```
level=WARN source=gpu.go:30 msg="error looking up system memory" error="open /proc/meminfo: no such file or directory"
```

Ollama no longer knows the system memory it uses to decide whether a model fits. **Not used.**

**A finding along the way: models entirely on the CPU.** The journal of every load (`journalctl -u ollama --since today | grep -E 'disabling mmap|load_mode ='`) shows `load_mode = mmap` for every model on the GPU, fully or partly, and `disabling mmap for llama-server load by default` with `load_mode = none` for every load with `num_gpu: 0`, before and during this step. With `llama3.1:8b` entirely on the CPU (node; the last command needs root):

```bash
cg=/sys/fs/cgroup/system.slice/ollama.service
grep -E '^(anon|file|file_mapped) ' $cg/memory.stat
sudo sh -c "for p in \$(cat $cg/cgroup.procs); do
  echo \"== \$(cat /proc/\$p/comm)\"
  grep -E '^(Rss|Pss_Anon|Pss_File)' /proc/\$p/smaps_rollup; done"
```

```
anon 9326080000
file 4096
file_mapped 0
== llama-server
Rss:             9080504 kB
Pss_Anon:        9066332 kB
Pss_File:          10417 kB
```

8.65 GiB of anonymous memory: ≈ 4.6 GiB of weights and the 4 GiB KV cache (32768 tokens × 128 KiB). The conclusion of step 7 holds for models partly on the GPU only; a model entirely on the CPU is memory the kernel cannot drop as cache. Two of them exceed `MemoryHigh=16G`: they are throttled, and with `MemorySwapMax=0` (step 18) nothing can go to swap either; at `MemoryMax` the runner is OOM-killed. The limits stay (this is a GPU server); the role's README records the caveat.

**Clean-up:** `sudo rm $d/lab0b-trial.conf && sudo systemctl daemon-reload` (the running process keeps the trial settings until the next restart, which the role run makes).

**Added to `roles/ollama/files/hardening.conf`:**

```ini
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
PrivateUsers=yes
MemoryDenyWriteExecute=yes
```

**Into the role:** the four directives above, then the control-node runs (`--check --diff`, real run; `hardening.conf` `changed`, recap `ok=23 changed=2 skipped=2 failed=0`). Running state: `PrivateUsers=yes`, `MemoryDenyWriteExecute=yes`, `SystemCallErrorNumber=1`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX`, only the two drop-ins in `/etc`. Score **1.5 OK**.

**What is still failed, and why** (`systemd-analyze security ollama.service --no-pager | grep '✗'`):

| Check | Value | Why it stays |
|---|---|---|
| `PrivateNetwork=` | 0.5 | Ollama serves clients over the network |
| `RestrictAddressFamilies=~AF_(INET\|INET6)`, `~AF_UNIX`, `~AF_NETLINK` | 0.3, 0.1, 0.1 | Allowed because they are needed |
| `IPAddressDeny=` | 0.2 | Ollama downloads models |
| `PrivateDevices=` | 0.2 | Would hide `/dev/nvidia*` (step 11) |
| `DeviceAllow=` | 0.1 | The list contains real hardware (the cards; `char-rtc` from `ProtectClock=`) |
| `ProcSubset=` | 0.1 | Hides `/proc/meminfo` (above) |
| `RootDirectory=`/`RootImage=` | 0.1 | Ollama runs in the host's root; an own image is out of scope |
| `SystemCallFilter=~@resources` | 0.2 | `@system-service` includes it; it holds thread affinity and memory policy, which llama.cpp uses to place its threads |
| `SystemCallFilter=~@privileged` | 0.2 | `@system-service` still contains privileged calls (`@chown`, `setuid`, `setgroups`, `chroot`, `bpf`, …) |
| `UMask=` | 0.1 | `0027` keeps files readable for the group `ollama`; the check wants `0077` |

The last one in the list of decisions: `@privileged` can be removed. `man systemd.exec`: when allow and deny lists are combined, the first assignment sets the default, and a later `~` assignment removes the listed calls from the allowed set. `systemd-analyze syscall-filter @privileged` lists what goes: `@chown`, `@clock`, `@module`, `@raw-io`, `@reboot`, `@swap`, `bpf`, `capset`, `chroot`, `pivot_root`, `setuid`, `setgroups`, `sethostname` and similar; nothing a single-user service that only writes files needs. Added after the allow line:

```ini
SystemCallFilter=~@privileged
```

`@resources` stays (llama.cpp's thread placement), and so does `UMask=0027`.

**Result:** `✓ SystemCallFilter=~@privileged … @privileged is not included`; both cards found within 4 seconds of the start; **1.4 OK** 🙂.

**Regression tests on the final configuration** (step 14, all of them): copy and delete, pull, `dims 384`, the container client (`{"version":"0.32.14"}`), `qwen3.8:27b` `100% GPU` on both cards (10554 / 11016 MiB), `Red`, CPU speed 13.5 tokens/s at 790% with `nr_throttled 0`; nothing in the journal.

## Step 16/19 — The demo service: a unit of our own with a secret

**Why:** Ollama's unit belongs to its installer; a service of our own shows what a unit can do from the start, and how a secret reaches a service without entering git. The service is deliberately trivial: `python3 -m http.server` on loopback.

**Documentation** (`man systemd.exec`, systemd 255):

- `DynamicUser=yes`: a user and group are allocated from 61184–65519 when the unit starts and released when it stops; nothing in `/etc/passwd`. It implies `RemoveIPC=`, `PrivateTmp=`, `NoNewPrivileges=`, `RestrictSUIDSGID=`, `ProtectSystem=strict` and `ProtectHome=read-only`.
- `StateDirectory=<name>`: systemd creates `/var/lib/<name>` for the service user, writable under `ProtectSystem=strict` (the modern replacement for `ReadWritePaths=` for a service's own data; the path is in `$STATE_DIRECTORY`). With a dynamic user the directory lives in `/var/lib/private/<name>`, inaccessible to unprivileged users, so that a recycled UID cannot reach old data; `/var/lib/<name>` is a symbolic link to it.
- `EnvironmentFile=`: read by the service manager (as root) shortly before the process starts, before any mount namespacing. A root-only file works for any service user. Without the `-` prefix a missing file stops the service from starting.

**Decisions:**

| Topic | Chosen | Alternative and why not |
|---|---|---|
| User | `DynamicUser=yes` | A system user created by the role: one more account to manage and remove |
| Data | `StateDirectory=lab0b-demo` (`/var/lib/lab0b-demo`), served by `http.server` | `ReadWritePaths=`: already shown with Ollama |
| Network | `127.0.0.1:8765` only (the port was free: `ss -ltnH 'sport = :8765'`) | Any wider binding exposes the demo |
| Secret | `/etc/lab0b-demo.env`, root:root `0600`, one variable `DEMO_TOKEN`, created by hand; the role only asserts it exists with that owner and mode | Ansible Vault (step 8) |

**Files** (`<repo>/ansible`):

- `roles/lab0b_demo/files/lab0b-demo.service`:

  ```ini
  [Unit]
  Description=Lab 0b demo service (python3 -m http.server)

  [Service]
  ExecStart=/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory /var/lib/lab0b-demo
  DynamicUser=yes
  StateDirectory=lab0b-demo
  EnvironmentFile=/etc/lab0b-demo.env

  [Install]
  WantedBy=multi-user.target
  ```

- `roles/lab0b_demo/tasks/main.yml`: `stat` of the secrets file and an `assert` (exists, `root`/`root`, `0600`; a clear message otherwise; works in check mode), the unit (`copy`, `0644`, `notify: Restart the demo service`), the service `enabled` + `started` with `daemon_reload: true`.
- `roles/lab0b_demo/handlers/main.yml`, `roles/lab0b_demo/README.md` (how to create the secret, how to remove the role).
- `lab0b.yml` (`hosts: z790`, `become: true`), imported at the end of `site.yml`.

**The secret, by hand** (node, root). `install` creates the file empty and already `0600`, so the value is never world-readable, not even for a moment; the value is random and never printed:

```bash
sudo install -o root -g root -m 0600 /dev/null /etc/lab0b-demo.env
printf 'DEMO_TOKEN=%s\n' "$(openssl rand -hex 16)" \
  | sudo tee /etc/lab0b-demo.env >/dev/null
sudo ls -l /etc/lab0b-demo.env
```

Result: `-rw------- 1 root root 44 … /etc/lab0b-demo.env`.

**Command** (node in `<repo>/ansible`, then the control node after `git pull --ff-only`; then from the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Result:**

- Lint on both: `Passed: 0 failure(s), 0 warning(s) in 24 files processed of 40 encountered`.
- **The first check mode run fails, as expected:**

  ```
  TASK [lab0b_demo : Keep the demo service enabled and running]
  fatal: [z790]: FAILED! => {"changed": false, "msg": "Could not find the requested service lab0b-demo: host"}
  PLAY RECAP
  z790 : ok=26 changed=1 unreachable=0 failed=1 skipped=2
  ```

  The same chain as Lab 0f's first run (step 8 there): in check mode the unit file is only reported as `changed`, not written, so systemd does not know the service the next task asks about. Only on a host where the unit does not exist yet.
- Real run: recap `ok=28 changed=3 failed=0` (the unit, the service started and enabled, the handler).

**Test the service** (node, no root):

```bash
systemctl show lab0b-demo --no-pager -p ActiveState,MainPID,User,DynamicUser
ls -ld /var/lib/lab0b-demo /var/lib/private/lab0b-demo
curl -s -o /dev/null -w 'http=%{http_code}\n' http://127.0.0.1:8765/
systemd-analyze security lab0b-demo.service --no-pager | tail -n 1
```

**Result:** `ActiveState=active`, `User=lab0b-demo`, `DynamicUser=yes`; `/var/lib/lab0b-demo -> private/lab0b-demo`, and `/var/lib/private/lab0b-demo` is `Permission denied` for an unprivileged user; `http=200`; **8.2 EXPOSED** 🙁. The six directives `DynamicUser=` implies are almost the set Ollama had after step 10 (8.3): they weigh little in the score.

**Test the secret** (node; the `sudo` lines need root; only the presence of the variable is counted, never its value):

```bash
p=$(systemctl show lab0b-demo -p MainPID --value)
systemctl show lab0b-demo --no-pager -p EnvironmentFiles,Environment
cat /proc/$p/environ >/dev/null && echo "readable" || true
sudo sh -c "tr '\0' '\n' < /proc/$p/environ" | grep -c '^DEMO_TOKEN='
sudo systemd-run --wait --pipe --quiet -p DynamicUser=yes \
  cat /etc/lab0b-demo.env
```

`sudo sh -c "… < file"`: with `sudo cmd < file` the redirection is done by the calling, unprivileged shell.

**Result:**

```
EnvironmentFiles=/etc/lab0b-demo.env (ignore_errors=no)
Environment=
cat: /proc/<pid>/environ: Permission denied
1
/usr/bin/cat: /etc/lab0b-demo.env: Permission denied
```

- systemd shows the path of the file, not its content.
- The variable is in the process environment; another user cannot read that environment, root can.
- A service with a dynamic user cannot read the file itself: only systemd does, before the process starts.

## Step 17/19 — Hardening the demo service

**Why:** how low the score can go for a service without a GPU, without downloads and without files of other users; the comparison with Ollama shows what the GPU and the network cost.

**Starting point** (`systemd-analyze security lab0b-demo.service --no-pager | grep '✗'`): almost the same list as Ollama's at step 4, minus the six directives `DynamicUser=` implies.

**Documentation for the new directives** (`man systemd.resource-control`, systemd 255): `IPAddressAllow=` and `IPAddressDeny=` filter IP packets in both directions for all sockets of the unit (ingress by source address, egress by destination), with eBPF on the cgroup. An address in the allow list is accepted, then one in the deny list is refused, otherwise accepted. `any` is `0.0.0.0/0 ::/0`, `localhost` is `127.0.0.0/8 ::1/128`.

**Decision:** the same set as Ollama (steps 9–15), plus what Ollama cannot have:

| Directive | Possible here because |
|---|---|
| `PrivateDevices=yes` | No devices needed |
| `ProcSubset=pid` | `http.server` does not read `/proc/meminfo` |
| `IPAddressDeny=any`, `IPAddressAllow=localhost` | Only local clients, nothing outgoing |
| `SystemCallFilter=~@privileged @resources` | No thread placement or memory policy |
| `UMask=0077`, `ProtectHome=yes` | Nobody else reads the demo's files; no need for `/home` even read-only |
| `RestrictAddressFamilies=AF_INET` | Only IPv4 sockets (`AF_INET AF_UNIX` was the alternative, without a measured need) |

Limits: `MemoryMax=64M`, `CPUQuota=50%`, `TasksMax=16`, and `Restart=on-failure`. Here the default start limit (5 starts in 10 s) does trigger: `RestartSec=` defaults to 100 ms.

**Added to `roles/lab0b_demo/files/lab0b-demo.service`:**

```ini
Restart=on-failure
MemoryMax=64M
CPUQuota=50%
TasksMax=16
ProtectHome=yes
PrivateDevices=yes
PrivateUsers=yes
CapabilityBoundingSet=
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_INET
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
UMask=0077
```

**Command** (control node): `--check --diff`, then the real run. **Result:** the unit `changed`, the handler restarts the service; recap `ok=28 changed=2 failed=0`.

**Test** (node, no root):

```bash
systemctl show lab0b-demo --no-pager -p ActiveState,NRestarts,MemoryCurrent,TasksCurrent
curl -s -o /dev/null -w 'http=%{http_code}\n' http://127.0.0.1:8765/
journalctl -u lab0b-demo -n 20 --no-pager
systemd-analyze security lab0b-demo.service --no-pager | tail -n 1
```

**Result:** active, `NRestarts=0`, `MemoryCurrent=10207232` (9.7 MiB), `TasksCurrent=1`; `http=200`; the journal shows the restart and `"GET / HTTP/1.1" 200`, no errors; **0.9 SAFE** 😀.

**Test the secret and the IP filter** (node; the `sudo` lines need root). A process cannot be put into a running service, but `IPAddressDeny=` is a property of the service's cgroup: a process moved into that cgroup gets the filter (and the resource limits), not the service's seccomp filter or namespaces. A short script, `work/lab0b/egress-test.py` (not in the repository), opens a TCP connection to `1.1.1.1:443` and one to `127.0.0.1:8765` and prints the result of each; it runs once normally as a control and once inside the cgroup (`echo $$ > …/cgroup.procs` moves the shell, `exec` replaces it with Python):

```bash
p=$(systemctl show lab0b-demo -p MainPID --value)
sudo sh -c "tr '\0' '\n' < /proc/$p/environ" | grep -c '^DEMO_TOKEN='
t=<repo>/work/lab0b/egress-test.py
python3 -I $t
cg=/sys/fs/cgroup/system.slice/lab0b-demo.service
sudo sh -c "echo \$\$ > $cg/cgroup.procs; exec python3 -I $t"
```

**Result:**

```
1
1.1.1.1:443: connected          # control, outside the service
127.0.0.1:8765: connected
1.1.1.1:443: timed out          # inside the service's cgroup
127.0.0.1:8765: connected
```

The secret still reaches the process under `PrivateUsers=` and `ProtectProc=`. The IP filter **drops** packets silently: the program sees a timeout, not "permission denied". When a service with `IPAddressDeny=` cannot reach something, it looks like an unreachable host.

**What is still failed** (`systemd-analyze security lab0b-demo.service --no-pager | grep '✗'`):

| Check | Value | Why it stays |
|---|---|---|
| `PrivateNetwork=` | 0.5 | It listens on the host's loopback; with an own network namespace the host could not reach it |
| `RestrictAddressFamilies=~AF_(INET\|INET6)` | 0.3 | `AF_INET` is allowed so that it can listen |
| `RootDirectory=`/`RootImage=` | 0.1 | It runs in the host's root |
| `DeviceAllow=` | 0.1 | `char-rtc:r` stays even with `PrivateDevices=yes`: `ProtectClock=yes` adds it |
| `IPAddressDeny=` | 0.1 | Partly: an allow list "with only localhost entries" |

**Comparison:**

| | Ollama | Demo |
|---|---|---|
| Score at the start | 9.2 UNSAFE | 8.2 EXPOSED (only `DynamicUser`, `StateDirectory`, `EnvironmentFile`) |
| Score at the end | 1.4 OK | 0.9 SAFE |
| What keeps the rest | network to clients and the internet, GPU devices, `/proc/meminfo`, thread placement | a network listener on loopback |

## Step 18/19 — Deliberate failures

**Why:** the restart, start-limit and OOM decisions of step 9 have only been read in the documentation so far. One question was open: does `Restart=on-failure` restart a service that `OOMPolicy=stop` has stopped?

All on the node; `kill`, `set-property` and moving a process into a service's cgroup need root.

**1. `kill -9` of Ollama.** SIGKILL is not one of the four "clean" signals, so `Restart=on-failure` applies.

```bash
systemctl show ollama --no-pager -p MainPID,NRestarts
sudo kill -9 "$(systemctl show ollama -p MainPID --value)"
sleep 15
systemctl show ollama --no-pager -p ActiveState,MainPID,NRestarts
journalctl -u ollama -n 30 --no-pager \
  | grep -E 'Main process exited|Failed with result|Scheduled restart|Started ollama|inference compute'
```

**Result:** a new `MainPID`, `NRestarts=1`, active. Journal: `Main process exited, code=killed, status=9/KILL`, `Failed with result 'signal'`, 4 s later `Scheduled restart job, restart counter is at 1`, `Started`, both cards found 4 s after the start.

**2. A crash loop and the start limit** (5 starts in 5 minutes, step 9). One start is already in the window; four more kills give starts 2–5, the fifth kill asks for a sixth. `[ "$pid" -gt 0 ]` matters: `kill -9 0` would kill the caller's own process group if Ollama is between restarts.

```bash
for i in 1 2 3 4 5; do
  pid=$(systemctl show ollama -p MainPID --value)
  echo "kill $i: pid=$pid"
  [ "$pid" -gt 0 ] && sudo kill -9 "$pid"
  sleep 8
done
systemctl show ollama --no-pager -p ActiveState,Result,NRestarts
journalctl -u ollama -n 40 --no-pager \
  | grep -E 'Scheduled restart|repeated too quickly|start-limit'
```

**Result:**

```
ActiveState=failed
Result=signal
NRestarts=6
… Scheduled restart job, restart counter is at 6.
… Start request repeated too quickly.
```

- The sixth start is refused and Ollama stays `failed`.
- `NRestarts` counts scheduled restarts, the refused one included (6, not 5).
- `Result=` keeps the cause of the last process failure (`signal`); the start limit shows up only in the journal (`Start request repeated too quickly`). When a service does not come back, read the journal, not just `Result=`.

Recovery: `reset-failed` clears the counter (without it, `start` works again only after the 5-minute window).

```bash
sudo systemctl reset-failed ollama
sudo systemctl start ollama
systemctl show ollama --no-pager -p ActiveState,Result,NRestarts
```

Result: active, `Result=success`, `NRestarts=0`, both cards found.

**3. OOM in the demo service** (`OOMPolicy=stop`, the default, and `Restart=on-failure`). A process moved into the service's cgroup (as for the IP filter in step 17) gets its memory limits; it allocates 200 MB under `MemoryMax=64M`, and the OOM killer takes the largest process in the cgroup, which is that process:

```bash
cg=/sys/fs/cgroup/system.slice/lab0b-demo.service
systemctl show lab0b-demo --no-pager -p MainPID,NRestarts
sudo sh -c "echo \$\$ > $cg/cgroup.procs; exec python3 -I -c 'b=b\"x\"*(200*1024*1024)'"
echo "exit=$?"
sleep 5
systemctl show lab0b-demo --no-pager -p ActiveState,Result,NRestarts,MainPID
journalctl -u lab0b-demo -n 15 --no-pager | grep -vE '"GET '
curl -s -o /dev/null -w 'http=%{http_code}\n' http://127.0.0.1:8765/
```

**First result: no OOM at all.** `exit=0`; the allocation succeeded and the service was untouched. The host has 8 GiB of swap (`/proc/swaps`), and the cgroup's own counters show where the memory went:

```bash
cg=/sys/fs/cgroup/system.slice/lab0b-demo.service
for f in memory.max memory.swap.max memory.peak memory.swap.peak memory.events; do
  printf '%s: ' $f; tr '\n' ' ' < $cg/$f; echo; done
```

```
memory.max: 67108864
memory.swap.max: max
memory.peak: 67108864
memory.swap.peak: 162553856
memory.events: low 0 high 0 max 629 oom 0 oom_kill 0 oom_group_kill 0 sock_throttled 0
```

RAM stopped exactly at the limit (hit 629 times) and 155 MiB went to swap. **`MemoryMax=` limits RAM only**; `MemorySwapMax=` (`man systemd.resource-control`: the limit on swap, `memory.swap.max`, none by default) is separate. Step 6 set it to 0 for the scope; the units did not.

**Decision:**

| Option | Effect | Against |
|---|---|---|
| **A (chosen):** `MemorySwapMax=0` for both services | `MemoryMax=` is a real ceiling: above it the OOM killer, as designed (`OOMPolicy=continue` kills Ollama's runner, the demo restarts) | No buffer: a peak above the limit is an OOM kill |
| B: no swap limit | Above `MemoryMax=` the service slows down through swap | A model or KV cache in swap means answers in minutes instead of an error a client can handle; the limit does not do what it says |
| C: a small swap limit (`MemorySwapMax=1G`) | A buffer for peaks | Hard to reason about, still slow |

Added to both roles (`hardening.conf` and `lab0b-demo.service`): `MemorySwapMax=0`. Check and real run from the control node: both files `changed`, both handlers restart their services, recap `ok=29 changed=4 failed=0`. Running state: `memory.swap.max` `0` and `MemorySwapMax=0` for both.

**The same test again:**

```
Killed
exit=137
… lab0b-demo.service: A process of this unit has been killed by the OOM killer.
… lab0b-demo.service: Failed with result 'oom-kill'.
… lab0b-demo.service: Scheduled restart job, restart counter is at 1.
… Started lab0b-demo.service - Lab 0b demo service (python3 -m http.server).
ActiveState=active  NRestarts=1  (new MainPID)  http=200
```

**Answer to the open question: yes.** `OOMPolicy=stop` stops the unit as a failure (`Result=oom-kill`), not as an ordinary stop, and `Restart=on-failure` brings it back (within the same second: `RestartSec=` defaults to 100 ms).

**4. OOM in Ollama** (`OOMPolicy=continue`). The memory limit is lowered for the test only with `systemctl set-property --runtime` (a file under `/run/systemd/system.control/`, gone after a reboot; the change applies at once, without a restart). No model is loaded, so a 6 GiB allocation is the largest process in the cgroup:

```bash
ollama ps
sudo systemctl set-property --runtime ollama MemoryMax=4G
systemctl show ollama --no-pager -p MemoryMax,MainPID,NRestarts,DropInPaths
cg=/sys/fs/cgroup/system.slice/ollama.service
sudo sh -c "echo \$\$ > $cg/cgroup.procs; exec python3 -I -c 'b=b\"x\"*(6*1024**3)'"
echo "exit=$?"
sleep 5
systemctl show ollama --no-pager -p ActiveState,MainPID,NRestarts,Result
grep -E '^(oom|oom_kill) ' $cg/memory.events
journalctl -u ollama -n 10 --no-pager | grep -E 'OOM|Failed with|Scheduled|Started'
curl -s localhost:11434/api/version
```

**Result:** `MemoryMax=4294967296`, a new drop-in `/run/systemd/system.control/ollama.service.d/50-MemoryMax.conf`; `Killed`, `exit=137`; the same `MainPID`, `NRestarts=0`, active; `oom 1`, `oom_kill 1`; the journal has only `A process of this unit has been killed by the OOM killer.`, no `Failed with result`, no restart; the API answers. `OOMPolicy=continue` keeps the service and loses only the victim.

**Undo** (not `systemctl revert ollama`: it removes every drop-in of the unit, the role's in `/etc` included):

```bash
sudo systemctl set-property --runtime ollama MemoryMax=32G
sudo rm /run/systemd/system.control/ollama.service.d/50-MemoryMax.conf
sudo systemctl daemon-reload
systemctl show ollama --no-pager -p MemoryMax,DropInPaths
cat /sys/fs/cgroup/system.slice/ollama.service/memory.max
```

Result: `MemoryMax=34359738368` in systemd and in the cgroup, only the two drop-ins in `/etc`.

## Step 19/19 — Final checks: lint, idempotency, a reboot

**Why:** the site must lint clean and be idempotent with both roles, and the order at boot (module → device rules → GPU wait → discovery) can only be tested by booting.

**Command** (node in `<repo>/ansible`, the control node after `git pull --ff-only`; then from the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
```

**Result:** `Passed: 0 failure(s), 0 warning(s) in 24 files processed of 40 encountered`, profile `production`, on both; check mode without a single diff, recap `ok=27 changed=0 unreachable=0 failed=0 skipped=2`.

**Reboot** (node, root): `sudo reboot`. Then (no root):

```bash
systemctl show modprobe@nvidia_uvm --no-pager -p Result
journalctl -b -o short-precise --no-pager \
  | grep -E 'modprobe@nvidia_uvm|Started ollama|Started lab0b-demo|inference compute'
systemctl show ollama --no-pager -p ActiveState,NRestarts
systemctl show lab0b-demo --no-pager -p ActiveState,NRestarts
curl -s localhost:11434/api/version; echo
curl -s -o /dev/null -w 'http=%{http_code}\n' http://127.0.0.1:8765/
systemd-analyze security ollama.service lab0b-demo.service --no-pager | tail -n 3
```

**Result:**

```
Result=success
14:24:37.780 systemd[1]: Starting modprobe@nvidia_uvm.service - Load Kernel Module nvidia_uvm...
14:24:37.972 systemd[1]: Finished modprobe@nvidia_uvm.service - Load Kernel Module nvidia_uvm.
14:24:39.002 systemd[1]: Started lab0b-demo.service - Lab 0b demo service (python3 -m http.server).
14:24:52.054 systemd[1]: Started ollama.service - Ollama Service.
14:24:57.861 ollama[…]: … msg="inference compute" id=0 … library=CUDA …
14:24:57.861 ollama[…]: … msg="inference compute" id=1 … library=CUDA …
ActiveState=active NRestarts=0     (both services)
{"version":"0.32.14"}
http=200
UNIT               EXPOSURE PREDICATE HAPPY
ollama.service          1.4 OK        🙂
lab0b-demo.service      0.9 SAFE      😀
```

The module is loaded before Ollama starts, both cards are found through CUDA, both services start on their own and keep their scores.

---

## Gotchas

- **`MemoryMax=` limits RAM only.** On a host with swap, set `MemorySwapMax=0` too, or a service above its limit goes to swap instead of being OOM-killed (step 18).
- **Ollama's memory is mostly page cache** of model files, including models already unloaded; `memory.current` is not its need. Layers on the CPU of a model partly on the GPU are mapped from the file; a model entirely on the CPU is loaded without mmap and is all anonymous memory (steps 7, 15).
- **The default start limit (5 starts in 10 s) never triggers with `RestartSec=3`**: set `StartLimitIntervalSec=`/`StartLimitBurst=` if a broken service must stop restarting (step 9).
- **`OOMPolicy=stop` (the default) stops the whole unit** when one process is OOM-killed; it counts as a failure, so `Restart=on-failure` brings it back. `OOMPolicy=continue` loses only the victim (steps 6, 18).
- **`DevicePolicy=`/`DeviceAllow=` apply to the whole cgroup**, the `+` prefix of `ExecStartPre=` included, and a `DeviceAllow=` group that does not exist at start is silently dropped: load the module first with `modprobe@<module>.service` (step 11).
- **A service without its GPU devices does not fail**: it waits, then runs on the CPU. Check `inference compute` lines and `ollama ps` after every change (steps 11, 14).
- **`ProcSubset=pid` hides `/proc/meminfo`**: Ollama keeps working, blind to system memory, with only a warning in the journal (step 15).
- **`SystemCallFilter=@system-service` still allows privileged calls**; add `SystemCallFilter=~@privileged` (step 15). Combine with `SystemCallErrorNumber=EPERM` so a missing call fails instead of killing the process with `SIGSYS`.
- **`IPAddressDeny=` drops packets silently**: a blocked connection times out (step 17).
- **`Result=` does not show the start limit**, and `NRestarts` counts the refused restart; read the journal (step 18).
- **Do not undo a `systemctl set-property --runtime` with `systemctl revert`**: it removes every drop-in of the unit, the role's in `/etc` included (step 18).
- **The first `--check` of a role that installs a new unit fails** at the task that starts it: the unit file is only reported, not written (step 16).
- **`sudo cmd < file`** redirects as the calling user; use `sudo sh -c "cmd < file"` (step 16).
