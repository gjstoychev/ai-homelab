# Lab 0a — Container from Scratch

Date: 2026-10-07 – 2026-10-11 · Z790, Ubuntu 24.04, kernel 7.0.0-34-generic (HWE). Guide: `docs/guides/lab0a.md`. Script: `scripts/minicontainer.sh`.

## Goal

Build a working container by hand in about 100 lines of Bash (namespaces, cgroups v2, `pivot_root`, network namespace with veth) so that container runtimes stop being magic.

Success criteria:

- PID 1 inside sees only its own processes.
- Separate hostname.
- `ls /` shows Alpine.
- Exceeding `memory.max` triggers an OOM kill recorded in `memory.events`.
- Ping across veth works.
- `lsns` shows distinct namespace inodes.
- The script cleans up after itself.

## What I did

1. Pre-flight: cgroup v2, controllers, AppArmor userns restriction, Docker/Ollama status.
2. Alpine minirootfs 3.24.2: metadata, pinned download, SHA256 check, extraction as an unprivileged user.
3. Namespaces one at a time: UTS; PID without and with `--fork`; PID with a fresh `/proc`; mount propagation (shared leak vs private); `chroot` vs `pivot_root`.
4. Side quest: a rootfs from nothing (`tiny/`, bash + 3 shared objects).
5. cgroups v2 by hand: inspected Ollama's systemd cgroup; created `lab0a`, set limits, triggered an OOM kill and a pids limit, removed it.
6. Network namespace + veth, ping to the host, cleanup.
7. User namespace as an unprivileged user: blocked by AppArmor; fixed with a dedicated `unshare` copy and its own AppArmor profile.
8. Assembled `scripts/minicontainer.sh` (81 lines), verified all criteria, viewed it from the host with `lsns`, compared with Docker (namespaces and start-up time).

## Measurements

| Check | Result |
|---|---|
| Rootfs | Alpine 3.24.2, 3.7 MB tarball, 8.7 MB extracted |
| `tiny/` rootfs (bash + libtinfo + libc + loader) | 3.9 MB |
| Mounts visible: `chroot` (same namespace, outside / inside) | 26 / 1 |
| Mounts: `pivot_root` (before / after `umount -l` of old root) | 28 / 2 |
| OOM test (`memory.max` 100M, swap 0, 200 MB allocation) | exit 137; `memory.events` max 18, oom 1, oom_kill 1; anon-rss 101884 kB |
| `pids.max` 20 vs 30 background sleeps | refused at 20 tasks; `pids.events` max 1 |
| veth ping (host ↔ namespace) | 0.077–0.148 ms; first packet slower (ARP) |
| Ollama cgroup (idle, no model) | `memory.current` ≈ 552 MiB (incl. page cache); `pids.current` 18; `TasksMax` = `pids.max` = 70833 (systemd default) |
| Start-up, 5 runs: `minicontainer.sh` / `docker run --rm alpine:3.24` | 0.619 s (~124 ms per run) / 2.589 s (~518 ms per run) |

Namespaces from the host (`lsns`): `minicontainer.sh` creates new uts, pid, mnt, ipc, cgroup, net; user and time are shared with the host. Docker creates new mnt, uts, ipc, pid, cgroup, net and time; only user is shared.

Follow-up checks (2026-10-11):

| Check | Result |
|---|---|
| Docker stack | Engine 29.8.0 (build 88096ef), containerd v2.3.5, runc 1.5.1 (OCI spec 1.3.0); no `/etc/docker/daemon.json`, so default configuration |
| Namespaces in the OCI spec Docker generates (`config.json` under `/run/containerd`) | mount, network, time, uts, pid, ipc, cgroup |
| Docker container time namespace | `time:[4026533223]` vs host `time:[4026531834]`; `timens_offsets` monotonic 0 0, boottime 0 0 |
| Qualys `aa-exec` bypass | `kernel.apparmor_restrict_unprivileged_unconfined = 0`; plain `unshare --user --map-root-user` is blocked, but `aa-exec -p trinity -- unshare --user --map-root-user` as an unprivileged user gives uid 0 and `CapEff 000001ffffffffff` in the user namespace |
| Permissive AppArmor profiles with `userns` | `trinity`, `chrome`, `flatpak` are loaded (none of the three programs is installed); no `busybox` or `nautilus` profile; `aa-exec` and `busybox` are installed |
| GPU kernel modules using `dmem` (71 modules for 7.0.0-34-generic) | `xe` and `amdgpu` call `drmm_cgroup_register_region` (built into the kernel); `ttm` charges (`dmem_cgroup_try_charge`/`uncharge`); none of the 5 NVIDIA 580.173.02 open modules reference `dmem` |

## What surprised me

- The `dmem` cgroup controller (device memory) exists on this kernel, but `dmem.capacity` is empty: NVIDIA 580 open modules do not register with it, so VRAM cannot be limited through cgroups. On this kernel only `xe` (Intel) and `amdgpu` (AMD) register VRAM regions (checked 2026-10-11).
- `chroot` hides host mounts from `/proc/mounts` (26 → 1 in the same namespace) but does not detach them; only `pivot_root` + `umount -l` does (28 → 2).
- An interactive `sudo unshare --pid` without `--fork` was dead before the prompt appeared: `.bashrc` forks at startup, that child became PID 1 and exited.
- `unshare()` moves the caller into new uts/mnt/net/ipc/cgroup namespaces immediately, but the PID namespace applies only to children (visible in `lsns`: the `unshare` parent is in five namespaces, only the shell in the new PID namespace).
- A non-interactive dash aborts on the first failed fork.
- Initial namespaces have fixed inode numbers (4026531832–4026531839); new ones are dynamic and recycled after a namespace dies.
- Docker also creates a time namespace: it is in the OCI spec Docker 29.8.0 generates with its default configuration, with zero offsets, so it changes nothing visible.
- systemd silently applies a `TasksMax` limit to every service.
- On Ubuntu 24.04 an unprivileged user can create a user namespace, but AppArmor moves it into the `unprivileged_userns` profile and denies `CAP_SYS_ADMIN` inside.
- Root in a user namespace has all capabilities (`CapEff 000001ffffffffff`) but still cannot write to `/etc`: access is checked against the UID outside.
- The container is not in a user namespace: root inside is root on the host, same as default Docker.
- The userns restriction can be bypassed on this host with one command: `kernel.apparmor_restrict_unprivileged_unconfined` is 0, so `aa-exec -p trinity` switches into a permissive profile whose program is not even installed (checked 2026-10-11).

## Mistakes and dead ends

- Predicted dozens of lines in `/proc/mounts` after `chroot`; it lists only mounts reachable from the process root.
- Predicted 11 failed forks in the pids test; dash stopped after the first.
- Used `ip -br addr` inside the container; `-br` is iproute2, Alpine's BusyBox `ip` does not support it.
- Predicted start-up in tens of ms; it was ~124 ms.
- Predicted Docker would share the time namespace; it created a new one.
- Accidentally ran an interactive `sudo unshare --pid`; nothing executed because every fork failed.
- Initially claimed Ollama's `OLLAMA_HOST=0.0.0.0` exposed it to the LAN; ufw only allows 11434 on Docker bridges and 172.18.0.0/16.
- Copied output before `sleep 30` had finished (Prep).

## Open questions

- Where do the ~124 ms of start-up go (CPU time is ~14 ms)? Profile in Lab 11.
- ~~Is a new time namespace a default of this Docker/runc version?~~ Resolved 2026-10-11: yes. Docker 29.8.0 requests it in the OCI spec with the default configuration; runc 1.5.1 creates what the spec lists. Offsets are zero.
- ~~Is `kernel.apparmor_restrict_unprivileged_unconfined` enabled on this host, and are the busybox/Nautilus profiles permissive? (Qualys 2025 bypasses.)~~ Resolved 2026-10-11: it is 0 and the `aa-exec` bypass works (see Measurements); there are no busybox or Nautilus profiles. Mitigated the same day: `kernel.apparmor_restrict_unprivileged_unconfined = 1` in `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf` (applied by hand); after that the `aa-exec` bypass fails with `write failed /proc/self/uid_map: Operation not permitted`, and `lab0a-unshare` still gets uid 0 and full capabilities.
- `/usr/local/bin/lab0a-unshare` is a copy: it does not receive util-linux security updates. The Ansible role must refresh it after upgrades, or it must be removed when not needed.
- ufw rules tied to Docker bridge names (`br-<id>`) break silently if a network is recreated; possible stale rules.
- NAT from the lab namespace to the internet (deferred to Lab 0c).

## Follow-ups for later labs

- Lab 0c: NAT for the lab namespace; how ufw, Docker and nftables rules coexist; pin Docker network names and subnets.
- Lab 0f: bubblewrap faces the same AppArmor userns restriction; same per-binary approach.
- Lab 11 (hardened variant A): add `/dev` (null, zero, random, urandom, tty), `/tmp`, read-only `/sys`, capability dropping, seccomp, a user namespace; avoid leaving the `unshare` parent inside the namespaces.
- Lab 1: decide on security updates vs pinned kernel/driver.
- Lab 1 (Ansible): move the hand-applied `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf` into a role, then re-check that the `aa-exec` bypass fails and `lab0a-unshare` still works.
