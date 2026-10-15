# Lab 0b — systemd as a Platform: Step-by-Step Guide

Status: work in progress. Last updated: 2026-10-15. Results on this hardware: `results/lab0b.md`.

## Overview

Ollama and a second service of my own run as systemd services with resource limits (`MemoryMax`, `CPUQuota`) and sandboxing directives (`ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`). `systemd-analyze security` gives the exposure score before and after; `systemd-run --scope` applies ad-hoc limits to any command. Configuration is deployed by an Ansible role.

The second service is a small demo service created for this lab, to practise a unit of our own and a file with secrets.

## Working conventions

- Same as Lab 0f: each step says where a command runs (node or control node), whether it needs root and whether it changes anything. Ansible runs from `<repo>/ansible` on the control node, always `--check --diff` first.
- Placeholders: `<repo>` is the checkout path, `<user>` the account on the node.

---

## Step 1/18 — The sandbox is active

**Why:** Claude's commands in this lab run in Claude Code's sandbox (read-only home, no D-Bus, no `systemctl`). Everything that touches systemd is run by the user.

**Command** (Claude, sandboxed; read-only):

```bash
cat /proc/self/attr/current
```

**Expected / Result:** `claude-bwrap (unconfined)`, the AppArmor label of the bwrap copy (Lab 0f, step 12).

## Step 2/18 — Versions and documentation

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

## Step 3/18 — Ollama today: unit, drop-in and cgroup

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
- The `ExecStartPre` waits up to 60 seconds for the GPU driver. It is a guard against a start-up race: without the wait, Ollama does not see both cards and runs on the CPU until the next restart. The `+` prefix runs this command with full privileges, outside the unit's sandboxing (to be confirmed in `man systemd.service`, step 9).

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

## Step 4/18 — Baseline exposure score

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
| Touch Go and CUDA | `MemoryDenyWriteExecute`, `SystemCallFilter`, `RestrictNamespaces`, `RestrictAddressFamilies` | `MemoryDenyWriteExecute` probably breaks CUDA; the address families must keep INET, INET6 and UNIX |
| Not applicable | `PrivateNetwork` (it serves clients), `PrivateUsers`, `IPAddressDeny` (it downloads models) | Stay failed, so the final score is not 0 |

## Step 5/18 — The second service: a demo

**Why:** a self-written service shows what the packaged Ollama unit cannot: our own unit file, a file with secrets, and a data directory that `ProtectSystem=strict` needs a `ReadWritePaths` entry for. It must be public, neutral and small, with no scripts in the repository.

**Decision:**

| Option | How | For | Against |
|---|---|---|---|
| **A (chosen):** `python3 -m http.server` | Serves a directory under `/var/lib/<demo>` on a loopback port; the secret is a variable from an `EnvironmentFile` | Nothing to install, plain directives without a script, enough for `ReadWritePaths` and limits | The service does not use the secret; the demo shows only the file's permissions and who can see it |
| B: `ExecStart` runs a small shell command that reads the secret | The variable demonstrably reaches the process | A more convincing secrets example | A shell line inside the unit, on the border of the "no scripts" rule |
| C: `LoadCredential=` instead of `EnvironmentFile` | systemd hands the secret to the service as a file only it can read | The modern way | `EnvironmentFile` would not be shown |

`LoadCredential=` stays as a comparison in the secrets decision (step 8).

## Step 6/18 — Ad-hoc limits with `systemd-run --scope`

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

## Step 7/18 — Ollama's memory with a model loaded (VRAM vs RAM)

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
- `anon` (≈ 524 MiB) and `shmem` (≈ 108 MiB) are what the kernel cannot simply drop (without swap). With the model fully on the GPU, that is ≈ 0.6 GiB.
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
- What cannot be dropped (`anon` + `shmem`) is 0.6–1.6 GiB in every case measured.

**Decision: a memory limit for Ollama.** `man systemd.resource-control` (systemd 255): `MemoryHigh=` is "the main mechanism to control memory usage of a unit": above it the processes are slowed down and memory is taken away aggressively, but not killed. `MemoryMax=` is the last line of defense: the OOM killer.

| Option | Directives | Against |
|---|---|---|
| A | `MemoryHigh=16G` only | No hard ceiling for the host |
| **B (chosen)** | `MemoryHigh=16G` + `MemoryMax=32G` | At the ceiling an OOM kill, and with the default `OOMPolicy=stop` the whole service stops |
| C | `MemoryMax=24G` only | No soft level: cache is dropped only at the ceiling, then the OOM killer |
| D | no limit | No protection for the rest of the host |

- `MemoryHigh=16G` is about ten times what Ollama cannot give back (up to 1.6 GiB measured), and below the page cache it accumulates when models are switched (22 GiB measured): the cache is reclaimed above it.
- `MemoryMax=32G` keeps at least half of the host's 64 GB for everything else. It can only be reached by memory that cannot be dropped, such as the KV cache of CPU layers with a very large context; then restarting Ollama is better than the kernel killing something else on the host.
- What happens when a limit is reached (`OOMPolicy=`, `Restart=`) is decided in step 9; the limits are tested in step 12.

## Step 8/18 — Design decisions

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
