# lab0b_demo

A small self-written service with a secret, for Lab 0b: `python3 -m http.server` on `127.0.0.1:8765`, serving `/var/lib/lab0b-demo`. It exists to show what a unit of our own can use and the packaged Ollama unit cannot. Remove the role when the lab is no longer needed.

## Before the first run

Create the secrets file by hand; it never enters git:

```bash
sudo install -o root -g root -m 0600 /dev/null /etc/lab0b-demo.env
echo 'DEMO_TOKEN=<any value>' | sudo tee /etc/lab0b-demo.env >/dev/null
```

The role stops with an error if the file is missing or is not `root:root 0600`.

## What it does

- Checks the secrets file (`stat` + `assert`; works in check mode).
- Installs `/etc/systemd/system/lab0b-demo.service` (root:root `0644`) and restarts the service when it changes.
- Keeps the service enabled and running.

## The unit

| Directive | Why |
|---|---|
| `DynamicUser=yes` | A user and group are allocated when the service starts and released when it stops; nothing in `/etc/passwd`. |
| `StateDirectory=lab0b-demo` | systemd creates `/var/lib/lab0b-demo` and gives it to the dynamic user; it stays writable under `ProtectSystem=strict`. |
| `EnvironmentFile=/etc/lab0b-demo.env` | Read by systemd (as root) before the process starts, so the service user never needs to read the file. Without a `-` prefix a missing file stops the service from starting. |
| `Restart=on-failure` | Restart after a crash. The default start limit (5 starts in 10 s) does trigger here: `RestartSec` is 100 ms by default. |
| `MemoryMax=64M`, `MemorySwapMax=0`, `CPUQuota=50%`, `TasksMax=16` | A small server: one process, a thread per request. Without `MemorySwapMax=0`, `MemoryMax=` limits RAM only and the rest goes to swap. |
| The hardening block | The same set as `ollama` (see `roles/ollama/README.md`), plus what Ollama cannot have: `PrivateDevices=yes`, `ProcSubset=pid`, `IPAddressDeny=any` with `IPAddressAllow=localhost` (all IP traffic of the unit, both directions, filtered with eBPF), `SystemCallFilter=~@resources`, `ProtectHome=yes`, `UMask=0077`, and only `AF_INET` sockets. |

## Removal

```bash
sudo systemctl disable --now lab0b-demo
sudo rm /etc/systemd/system/lab0b-demo.service /etc/lab0b-demo.env
sudo systemctl daemon-reload
```

Then remove `lab0b.yml` from `site.yml`. systemd keeps the state directory of a dynamic user under `/var/lib/private/lab0b-demo`; remove it too.
