# Lab 0a — Container from Scratch: Step-by-Step Guide

Status: work in progress (steps 1–4 done, step 5 next). Last updated: 2026-10-07.

## Overview

Lab 0a builds a working container by hand in about 100 lines of Bash, so that Podman, gVisor and Kubernetes stop being magic. Every layer a container runtime adds is assembled manually and verified on its own before moving on.

**What we build:** `minicontainer.sh`, which starts a shell in an isolated environment using `unshare` (UTS, PID, mount, net, user namespaces), manual cgroups v2, `pivot_root`, and `ip netns` with a veth pair. The same script becomes variant A of Lab 11 (hardened sandbox comparison), so it is worth keeping clean.

**Success criteria:**

- `ps` inside shows only the container's processes, and the shell is PID 1.
- `hostname` inside differs from the host; `ls /` shows Alpine, not the host.
- A process exceeding `memory.max` is killed, and `memory.events` shows `oom_kill 1`.
- `ping` from the container to the host end of the veth works.
- `lsns` shows distinct namespace inodes for the container.
- The script cleans up after itself: no leftover cgroup, netns or veth.

**Environment:** Z790 (i7-14700, 64 GB DDR5, 2× RTX 5060 Ti), Ubuntu 24.04 with HWE kernel 7.0.0-34-generic. The lab uses no GPU. Ghostwheel is normally stopped, so experiments with cgroups and networking do not affect a running service.

**Why it matters for AI infrastructure:** every inference server, sandbox and Kubernetes pod in later labs is built from these same primitives. Knowing which layer does what is what makes later debugging possible.

## Working conventions

- **Work inside `tmux`.** The server is managed over WiFi; a dropped SSH session mid-experiment leaves namespaces and cgroups hanging. Keep two windows: one inside the container, one on the host to watch `/sys/fs/cgroup/lab0a/` and `lsns`.
- **One command at a time.** Run it, read the output, understand it, then move on. Unexpected output is data, not noise.
- **Working directory: `~/ai-homelab/work/lab0a`.** `work/` is gitignored, so binary files never land in public history, and everything in it must be recreatable from scripts (`git clean -fdx` deletes it). Not in `/tmp` (wiped on reboot, often mounted `noexec`); owned by your user, which the rootless step requires. Models and other large or expensive files never go here. (Steps 2–4 originally ran in `~/lab/lab0a` and were moved; the commands below use the new path.)
- **`sudo` until the rootless step.** Creating a namespace without a user namespace requires `CAP_SYS_ADMIN`. Unprivileged creation goes through a user namespace, which AppArmor restricts on Ubuntu 24.04.
- **Network choice: `10.200.0.0/24` for the veth.** Docker is active and owns `docker0` in `172.17.0.0/16`; a separate subnet avoids overlapping routes.
- **No unplanned `apt upgrade` during the lab.** It can pull a new kernel and an NVIDIA DKMS rebuild; driver lifecycle belongs to Lab 1.
- **Documentation:** findings go into `results/lab0a.md` as they happen; useful commands into `docs/runbook.md`; this procedure into `docs/guides/lab0a.md`; all repo content in English.

## Step 1 — Pre-flight check

The kernel supports everything the lab needs, but AppArmor blocks unprivileged user namespaces and Docker is active; both shape later steps.

```bash
stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers; sysctl kernel.apparmor_restrict_unprivileged_userns user.max_user_namespaces; systemctl is-active docker podman ollama 2>&1
```

**Why each part:**

- `stat -fc %T /sys/fs/cgroup` must print `cgroup2fs`: a pure cgroups v2 unified hierarchy, one tree for all controllers, not the v1 forest of the RHEL 6 era.
- `cgroup.controllers` lists what the kernel offers at the root. We need `memory`, `pids` and `cpu`.
- `apparmor_restrict_unprivileged_userns`: if `1`, the rootless step here and bubblewrap in Lab 0f fail with `Permission denied` and no obvious cause. Fix later with an AppArmor profile for the specific binary, never by disabling the protection globally.
- `user.max_user_namespaces` must be non-zero.
- `systemctl is-active`: Docker matters for its `FORWARD` rules (NAT stretch goal); Ollama is a ready example of a real systemd cgroup under `system.slice`. Note: `inactive` is also printed for a unit that does not exist.

**Result on Z790 (2026-10-07):**

| Check | Value | Meaning |
| --- | --- | --- |
| cgroup filesystem | `cgroup2fs` | Unified v2 hierarchy |
| Controllers | cpuset cpu io memory hugetlb pids rdma misc dmem | All needed; `dmem` is new |
| `apparmor_restrict_unprivileged_userns` | 1 | Rootless step needs an AppArmor profile |
| `user.max_user_namespaces` | 236110 | Fine |
| docker / podman / ollama | active / inactive / active | Plan around Docker networking |

**The surprise: `dmem`.** A recent controller that limits device memory (VRAM) through cgroups, like `memory.max` does for RAM. It only works with drivers that register with it; whether NVIDIA 580 open modules do is an open question for the cgroups step.

## Steps 2–4 — Root filesystem

The container's userland is Alpine minirootfs 3.24.2: a 3.7 MB tarball, 8.7 MB extracted, checksum-verified, extracted as your own user.

### Step 2 — Read the release metadata

```bash
mkdir -p ~/ai-homelab/work/lab0a && cd ~/ai-homelab/work/lab0a && curl -fsSL https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml | awk 'BEGIN{RS="\n-"} /flavor: alpine-minirootfs/'
```

- **Metadata first, not the tarball.** Never hardcode a version from memory. The YAML gives the exact file name for the current stable release and its SHA256.
- **`awk` with `RS="\n-"`** splits the YAML into records at each leading dash and prints only the minirootfs record; no YAML parser needed.
- Result: version 3.24.2, released 2026-09-17, size 3701382 bytes, SHA256 `c5ca053c…90388677`.

### Step 3 — Pinned download and checksum

```bash
cd ~/ai-homelab/work/lab0a && curl -fsSLO https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.2-x86_64.tar.gz && echo "c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677  alpine-minirootfs-3.24.2-x86_64.tar.gz" | sha256sum -c -
```

- **`v3.24` in the path, not `latest-stable`.** Metadata tells us what is current; the download uses an exact path so the script always fetches the same rootfs and measurements stay comparable. The same rule applies later to driver and image versions.
- **`-f`** makes `curl` fail on HTTP 404 instead of silently saving an error page as a "tarball". **`-O`** keeps the original file name.
- **`sha256sum -c -`** reads `<hash>  <file>` (two spaces) from stdin. Expect `OK`; on `FAILED`, stop and extract nothing.
- **Limitation:** the checksum comes from the same server as the file. It proves integrity, not authenticity. Alpine also publishes a GPG signature; full signature verification belongs to Lab 11.
- `dl-cdn.alpinelinux.org` is a CDN that picks a nearby node; any official mirror gives the same guarantee because the checksum is verified.
- Result: `alpine-minirootfs-3.24.2-x86_64.tar.gz: OK`.

### Step 4 — Extract and inspect

```bash
mkdir rootfs && tar -xzf alpine-minirootfs-3.24.2-x86_64.tar.gz -C rootfs && ls rootfs && du -sh rootfs && ls -l rootfs/bin | head -5 && ls -A rootfs/dev rootfs/proc
```

- **No `sudo`.** Files belong to `llama`, which the rootless step needs. As a normal user `tar` cannot create device nodes or change owners; there were no warnings, so the archive has none.
- **`ls rootfs`** shows the familiar layout. This is the whole "operating system" of the container, without a kernel: the kernel is the host's 7.0, shared. That is the core difference between a container and a VM.
- **`du -sh`**: 8.7 MB, versus hundreds of MB for an Ubuntu rootfs.
- **`ls -l rootfs/bin`**: almost everything is a symlink to `/bin/busybox`. One binary acts as `sh`, `ls`, `ps`, `mount` depending on the name it was called by.
- **`rootfs/dev` and `rootfs/proc` are empty.** `/proc` is not files on disk but a window into the kernel; it must be *mounted* inside the new PID namespace, or `ps` shows the host's processes.
- **The symlinks are absolute** (`arch -> /bin/busybox`). From the host, `rootfs/bin/ash` points to the host's `/bin/busybox`. An absolute path resolves against the process's current root, so the rootfs only comes alive after `chroot` or `pivot_root`.

## Step 5 — First namespace: UTS (next to run)

The UTS namespace isolates only the hostname and domain name, which makes it the safest way to see the whole namespace mechanism with no side effects.

```bash
sudo unshare --uts sh -c 'hostname lab0a; echo "inside:  $(hostname)  $(readlink /proc/self/ns/uts)"'; echo "outside: $(hostname)  $(readlink /proc/self/ns/uts)"
```

- **`unshare --uts`** creates a new UTS namespace and runs `sh` in it. Inside, `hostname lab0a` changes the name only in that namespace.
- **`readlink /proc/self/ns/uts`** prints the namespace identifier, for example `uts:[4026531838]`. The number is an inode. Two processes share a namespace exactly when the numbers match; this is how `lsns` and runtimes like Podman tell who is where.
- **After exit** the host is still `z790`. A namespace disappears when its last process exits; nothing to clean up.
- **Why `sudo`:** creating a namespace without a user namespace requires `CAP_SYS_ADMIN`.

**Expected:** two lines with different hostnames (`lab0a` / `z790`) and different `uts:[...]` numbers.

**Actual:** *to be filled in when run.*

## Upcoming steps

The rest of the lab adds one layer per step; commands are written into this guide as each step is run, because each depends on the previous step's actual output.

1. **PID namespace.** First without `--fork` to see why it fails, then with `--fork` but no new `/proc` to see `ps` lie (it shows host processes), then with a mount namespace and a fresh `/proc`: the shell becomes PID 1.
2. **Mount namespace and propagation.** Why mounts inside can leak to the host unless propagation is made `private` first.
3. **`chroot` versus `pivot_root`.** `chroot` only changes the path lookup root and can be escaped; `pivot_root` swaps the root mount and lets the old root be unmounted completely.
4. **cgroups v2 by hand.** Create `/sys/fs/cgroup/lab0a`, enable controllers via `cgroup.subtree_control` (and meet the "no internal processes" rule), set `memory.max`, `pids.max`, `cpu.max`, move the shell in, trigger an OOM kill, read `memory.events`. Look at how systemd places Ollama under `system.slice`. Check whether `dmem` has any regions registered for the NVIDIA GPUs.
5. **Network namespace and veth.** `ip netns`, a veth pair, `10.200.0.0/24`, ping to the host end. Stretch goal: NAT to the internet, which will collide with Docker's `FORWARD DROP` (a bridge to Lab 0c).
6. **User namespace (rootless).** Root inside maps to an unprivileged UID outside. Hits the AppArmor restriction; fix with a profile for the specific binary.
7. **Assemble `minicontainer.sh`** (~100 lines) with cleanup on exit, then compare against Podman with `lsns` and `/proc/<pid>/ns/*`, plus a start-up time comparison.
8. **Write up** `results/lab0a.md`, runbook entries, this guide, and a thin Ansible role `lab_tools`.

## Gotchas and notes so far

- **`cd` inside an `&&` chain persists.** `mkdir -p ~/ai-homelab/work/lab0a && cd ~/ai-homelab/work/lab0a && …` leaves the shell in that directory; check the prompt before the next command.
- **AppArmor and user namespaces.** Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns = 1`. The same wall appears in the rootless step and in Claude Code's bubblewrap sandbox (Lab 0f); solve it once, per binary.
- **`systemctl is-active` cannot tell "stopped" from "not installed".** Both print `inactive`.
- **Absolute symlinks in the rootfs** only resolve correctly after the root changes.
- **Pin versions, read metadata.** Use `latest-*` only to discover; download by exact version.
- **Checksum ≠ signature.** Integrity from the same server, authenticity needs the GPG signature (Lab 11).
- **Docker on the same host** owns `172.17.0.0/16` and sets `FORWARD` to `DROP`; plan subnets and NAT around it.
