# ollama

systemd configuration for an Ollama installed with its official install script. Lab 0b.

## What it does

- Installs two drop-ins in `/etc/systemd/system/ollama.service.d/` (root:root `0644`) and restarts Ollama (with `daemon-reload`) when either changes:
  - `override.conf`: listen on all interfaces (`OLLAMA_HOST=0.0.0.0:11434`, for other clients on the server) and wait up to 60 seconds for the GPU driver before starting (`ExecStartPre=+…nvidia-smi -L`). Without the wait Ollama can start before both cards are visible and stay on the CPU until the next restart.
  - `hardening.conf`: restart policy, start limit, OOM policy and sandboxing directives (see below).
- Keeps the service enabled and running.

It does not install Ollama and does not manage its version.

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
| `Wants=`/`After=modprobe@nvidia_uvm.service` | A `DeviceAllow=` group that does not exist when the unit starts is silently dropped. udev loads `nvidia_uvm` at boot; this guarantees it is loaded before Ollama starts. |
