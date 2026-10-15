# ollama

systemd configuration for an Ollama installed with its official install script. Lab 0b.

## What it does

- Installs two drop-ins in `/etc/systemd/system/ollama.service.d/` (root:root `0644`) and restarts Ollama (with `daemon-reload`) when either changes:
  - `override.conf`: listen on all interfaces (`OLLAMA_HOST=0.0.0.0:11434`, for other clients on the server) and wait up to 60 seconds for the GPU driver before starting (`ExecStartPre=+…nvidia-smi -L`). Without the wait Ollama can start before both cards are visible and stay on the CPU until the next restart.
  - `hardening.conf`: restart policy, start limit, OOM policy and sandboxing directives (see below).
- Keeps the service enabled and running.

It does not install Ollama and does not manage its version.

## Not used, on purpose

- `PrivateDevices=yes`: hides `/dev/nvidia*`.
- `ProcSubset=pid`: hides `/proc/meminfo`; Ollama logs `error looking up system memory` and decides blind whether a model fits.
- `PrivateNetwork=`, `IPAddressDeny=`: Ollama serves clients and downloads models.

## Caveat: models entirely on the CPU

With a model partly on the GPU, its CPU layers are mapped from the model file and can be reclaimed. With a model entirely on the CPU, Ollama 0.32.14 disables mmap (`disabling mmap for llama-server load by default`, `load_mode = none`): weights and KV cache are anonymous memory (8.7 GiB for `llama3.1:8b` with a 32768-token context). Two such models exceed `MemoryHigh=16G` and are throttled hard: none of it is cache, and `MemorySwapMax=0` keeps it out of swap; at `MemoryMax` the runner is OOM-killed.

## Why drop-ins

Ollama's installer (`scripts/install.sh`) rewrites `/etc/systemd/system/ollama.service` on every run and then restarts the service; it never touches `ollama.service.d/`. Changes made in the unit itself would be lost on the next upgrade, drop-ins are not. Caveat: a drop-in cannot see what a new version puts into the base unit; check `systemctl cat ollama` after an upgrade.

## hardening.conf

| Directive | Why |
|---|---|
| `StartLimitIntervalSec=5min`, `StartLimitBurst=5` | At most 5 starts in 5 minutes, then the unit stays `failed` instead of restarting forever. The default (5 in 10 s) never triggers with `RestartSec=3`. `systemctl reset-failed ollama` clears the counter. |
| `Restart=on-failure` | Restart after a crash, not after a clean exit (the installer's unit has `Restart=always`). |
| `OOMPolicy=continue` | An OOM kill takes only the victim, normally the model runner (`llama-server`); the server stays up. The default, `stop`, stops the whole service. |
| `NoNewPrivileges=yes` | No privilege gain through setuid/setgid binaries or file capabilities. |
| `PrivateTmp=yes` | Private `/tmp` and `/var/tmp`, removed when the service stops. |
| `ProtectSystem=strict` | The whole file system is read-only for Ollama, except `/dev`, `/proc` and `/sys`. |
| `ReadWritePaths=/usr/share/ollama/.ollama -/usr/share/ollama/.nv` | What Ollama writes: models, cache and its key (`~/.ollama`), the CUDA compute cache (`~/.nv`; `-` skips it when it does not exist). Ollama's home is `/usr/share/ollama`, under `/usr`. With `OLLAMA_MODELS` set elsewhere, add that path. |
| `ProtectHome=yes` | `/home`, `/root` and `/run/user` are empty and inaccessible. |
| `DevicePolicy=closed`, `DeviceAllow=char-nvidia rw`, `DeviceAllow=char-nvidia-uvm rw` | Only the standard pseudo devices and the NVIDIA driver's device groups from `/proc/devices` (the cards, `nvidiactl`, `nvidia-modeset`; unified memory). No `/dev/dri`, `nvidia-caps`, disks. Enforced with eBPF for the whole cgroup, so the `+` of `ExecStartPre=` does not bypass it. Groups, not paths: the number of cards can change. `PrivateDevices=yes` would hide `/dev/nvidia*`. |
| `MemoryHigh=16G`, `MemoryMax=32G`, `MemorySwapMax=0` | Most of what Ollama's cgroup counts is page cache of model files, including models already unloaded; above `MemoryHigh` the kernel reclaims it (and throttles). What cannot be reclaimed is 0.6–1.6 GiB with models on the GPU, plus the KV cache of layers on the CPU when a model does not fit into VRAM. `MemoryMax` keeps at least half of the host's 64 GB for everything else; reaching it means an OOM kill (`OOMPolicy=continue`). `MemoryMax=` limits RAM only: without `MemorySwapMax=0` the rest goes to swap (8 GiB on this host) and the limit does not hold. |
| `CPUQuota=1600%` | One model runner on the CPU uses 8 threads (about 800%); two can run unthrottled, and at least 12 of the 28 CPUs stay for the host. |
| `TasksMax=512` | 21 tasks idle, about 55 more per loaded model runner (peak 76 with one); the default (70833) is no limit. |
| `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups` | `/proc/sys`, `/sys` and the cgroup tree read-only, no module loading, no kernel log. `nvidia_uvm` is loaded before Ollama by `modprobe@`. |
| `ProtectClock`, `ProtectHostname` | No changes to the clock or the host name. `ProtectClock` also allows `char-rtc` read-only. |
| `ProtectProc=invisible` | Processes of other users are hidden in `/proc`. |
| `PrivateMounts=yes` | Mounts made by the service stay private. |
| `CapabilityBoundingSet=` (empty) | No capabilities at all; Ollama runs as `ollama` and needs none. `ExecStartPre=+` is not affected. |
| `RestrictSUIDSGID`, `RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`, `SystemCallArchitectures=native` | No SUID/SGID files, no realtime scheduling, no new namespaces, no personality changes, native system calls only. |
| `RemoveIPC=yes` | IPC objects of `ollama` are removed when the service stops. |
| `UMask=0027` | Files Ollama creates are not world-readable (group `ollama` keeps read access). |
| `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK` | Only local, IP and netlink sockets can be created. Incoming connections are not affected. |
| `SystemCallFilter=@system-service`, `SystemCallFilter=~@privileged`, `SystemCallErrorNumber=EPERM` | systemd's set for ordinary services (`ioctl`, which CUDA uses, is in it), minus the privileged calls it still contains (`@chown`, `setuid`/`setgroups`, `chroot`, `bpf`, …). A system call outside it fails with `EPERM` instead of killing the process with `SIGSYS`. `@resources` (thread affinity, memory policy) stays allowed: llama.cpp places its threads. |
| `PrivateUsers=yes` | Own user namespace: only `root` and `ollama` map to themselves, everyone else is `nobody`; no capabilities on the host. The GPU device nodes are world-accessible, so the `render`/`video` groups are not needed. |
| `MemoryDenyWriteExecute=yes` | No writable and executable memory (no JIT). CUDA in this Ollama version loads ready-made kernels for these cards; re-test after upgrades. |
| `Wants=`/`After=modprobe@nvidia_uvm.service` | A `DeviceAllow=` group that does not exist when the unit starts is silently dropped. udev loads `nvidia_uvm` at boot; this guarantees it is loaded before Ollama starts. |
