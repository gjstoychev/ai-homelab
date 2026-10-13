# Lab 0a — Container from Scratch: Step-by-Step Guide

Status: complete. Last updated: 2026-10-11.

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
- **No unplanned `apt upgrade` during the lab.** It can pull a new kernel and NVIDIA DKMS rebuild; driver lifecycle belongs to Lab 1.
- **Documentation:** findings go into `results/lab0a.md` as they happen; useful commands into `docs/runbook.md`; all repo content in English.

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

- **No `sudo`.** Files belong to your own user, which the rootless step needs. As a normal user `tar` cannot create device nodes or change owners; there were no warnings, so the archive has none.
- **`ls rootfs`** shows the familiar layout. This is the whole "operating system" of the container, without a kernel: the kernel is the host's 7.0, shared. That is the core difference between a container and a VM.
- **`du -sh`**: 8.7 MB, versus hundreds of MB for an Ubuntu rootfs.
- **`ls -l rootfs/bin`**: almost everything is a symlink to `/bin/busybox`. One binary acts as `sh`, `ls`, `ps`, `mount` depending on the name it was called by.
- **`rootfs/dev` and `rootfs/proc` are empty.** `/proc` is not files on disk but a window into the kernel; it must be *mounted* inside the new PID namespace, or `ps` shows the host's processes.
- **The symlinks are absolute** (`arch -> /bin/busybox`). From the host, `rootfs/bin/ash` points to the host's `/bin/busybox`. An absolute path resolves against the process's current root, so the rootfs only comes alive after `chroot` or `pivot_root`.

## Step 5 — First namespace: UTS

The UTS namespace isolates only the hostname and domain name, which makes it the safest way to see the whole namespace mechanism with no side effects.

```bash
sudo unshare --uts sh -c 'hostname lab0a; echo "inside:  $(hostname)  $(readlink /proc/self/ns/uts)"'; echo "outside: $(hostname)  $(readlink /proc/self/ns/uts)"
```

- **`unshare --uts`** creates a new UTS namespace and runs `sh` in it. Inside, `hostname lab0a` changes the name only in that namespace.
- **`readlink /proc/self/ns/uts`** prints the namespace identifier, for example `uts:[4026531838]`. The number is an inode. Two processes share a namespace exactly when the numbers match; this is how `lsns` and runtimes like Podman tell who is where.
- **After exit** the host is still `z790`. A namespace disappears when its last process exits; nothing to clean up.
- **Why `sudo`:** creating a namespace without a user namespace requires `CAP_SYS_ADMIN`.

**Expected:** two lines with different hostnames (`lab0a` / `z790`) and different `uts:[...]` numbers.

**Actual:** `inside: lab0a uts:[4026533010]` / `outside: z790 uts:[4026531838]`. The host value 4026531838 is 0xEFFFFFFE, a fixed constant the kernel gives the initial UTS namespace; new namespaces get dynamically allocated numbers. Seeing that constant means "host namespace".

## Step 6 — PID namespace without `--fork` (deliberately broken)

Shows why `--fork` is mandatory by leaving it out.

```bash
sudo unshare --pid sh -c 'echo "sh PID: $$"; ls / >/dev/null; echo "after 1st child"; ls / >/dev/null; echo "after 2nd child"'
```

- **`unshare()` does not move the calling process into the new PID namespace**, only its future children. `sh` stays in the host namespace, so `$$` is an ordinary host PID.
- **The first `ls` is the first child in the new namespace and becomes its PID 1** (its init). When it exits, the namespace has no init, and the kernel refuses to create new processes in it.
- **The second `ls` fails** with a fork error. The kernel returns `ENOMEM`, so messages often say "Cannot allocate memory", which is misleading: there is plenty of memory, the namespace is dead.
- **Fix:** `unshare --fork` forks first and runs `sh` as the child, so `sh` itself becomes PID 1 and lives as long as you work.

**Actual:** `sh PID: 6000`, `after 1st child`, `sh: 1: Cannot fork`. The shell exited at the error, so `after 2nd child` never printed.

**Why `--fork` is needed at all:** a process's PID is assigned at birth and cannot change while it runs, so the only way into a new PID namespace is to be born there. `unshare --uts/--mount/--net` move the calling process immediately; PID (and time) namespaces only apply to the caller's future children. Without `--fork`, `unshare` execs `sh` in place (same host PID); with `--fork`, it forks once, the child is born as PID 1 in the new namespace and execs `sh`, while the parent waits on the host.

**Accidental interactive variant:** `sudo unshare --pid` with no command starts an interactive root `bash` without `--fork`. It printed `fork: Cannot allocate memory` before the prompt even appeared: `.bashrc` forks at startup (e.g. `dircolors`, `lesspipe`), that child became PID 1 and exited. Every later external command, including `sudo`, failed to fork, so nothing ran; only the builtin `exit` worked. Note that such a shell is root on the host (no mount namespace, no root change).

## Step 7 — PID namespace with `--fork`, but no new `/proc`

```bash
sudo unshare --pid --fork sh -c 'echo "sh PID: $$"; ps -o pid,comm | head -5'
```

**Actual:** `sh PID: 1`, but `ps` lists `1 systemd`, `2 kthreadd`, `3 pool_workqueue_release`, `4 kworker/R-rcu_gp`: the host's processes.

- The PID namespace works: `sh` is PID 1 inside it.
- `ps` does not ask the kernel "which processes can I see"; it reads the `/proc` directory. The `/proc` it sees is mounted for the host's PID namespace, and a `proc` mount always shows the processes of the PID namespace it was mounted for.
- Two PID 1s at once, both true: `sh` is 1 in the new namespace, `systemd` is 1 in the host's. Kernel isolation and what the tools report are different things.

## Step 8 — Mount namespace and a fresh `/proc`

```bash
sudo unshare --pid --fork --mount-proc sh -c 'echo "sh PID: $$"; ps -o pid,comm'
```

- **`--mount-proc`** implies `--mount` and mounts a new `proc` on `/proc`, this time for the new PID namespace.
- **Why a mount namespace is mandatory here:** mounting a new `/proc` without one would mount it over the host's `/proc` for everyone; `ps`, `top` and systemd on the host would suddenly see an almost empty world until it is unmounted.
- **Propagation:** `unshare` makes mounts in the new namespace `private` by default, so they do not leak to the host. It matters explicitly for `pivot_root`.

**Actual:** `sh PID: 1`, and `ps` shows only `1 sh` and `2 ps`. First success criterion met: inside sees only its own processes, and the shell is PID 1. The filesystem is still the host's (`ls /` would show Ubuntu); changing the root comes next.

## Steps 9–10 — Mount propagation: leak versus private

### Step 9 — Deliberate leak

```bash
mkdir -p mnt-test && sudo unshare --mount --propagation shared mount -t tmpfs lab0a-leak "$PWD/mnt-test"; findmnt "$PWD/mnt-test"
```

- **systemd makes every host mount `shared`:** mounts are in a peer group, and a mount in one member propagates to all others. Convenient for the host (plug in a USB disk, everyone sees it).
- **A new mount namespace copies the mounts.** With `--propagation shared` the copies stay in the *same* peer group as the host's.
- **The tmpfs mounted inside propagates back to the host.** The namespace ends as soon as `mount` returns, but the mount stays on the host.
- **Actual:** `findmnt` on the host showed `lab0a-leak tmpfs` on `work/lab0a/mnt-test` after the namespace was gone. A container working this way would leave its mounts behind when stopped.

### Step 10 — Clean up and contrast with private

```bash
sudo umount "$PWD/mnt-test" && sudo unshare --mount --propagation private mount -t tmpfs lab0a-private "$PWD/mnt-test"; findmnt "$PWD/mnt-test" || echo "no mount on host"
```

- `umount` removes the leaked mount; `&&` stops the chain if cleanup fails.
- **`--propagation private`** takes the namespace's copies out of the host's peer group, so a mount inside never leaves.
- `findmnt` exits non-zero when nothing matches; the `echo` makes "nothing" explicit.
- **Actual:** `no mount on host`. `lab0a-private` existed only inside the namespace and vanished with it.

**Takeaway:** this is why `unshare` defaults to `private` and why runtimes like Podman set propagation explicitly for every container. It is also a precondition for `pivot_root`, which refuses to work on shared mounts.

## Step 11 — `chroot` into Alpine

**Where Alpine fits:** the rootfs from steps 2–4 is the container's *image*: its entire userland. `docker pull alpine` does essentially what steps 2–4 did by hand (download a tarball, verify its digest, extract it). This step is the first time it is used: every tool that runs below (`sh`, `head`, `ps`, `wc`) is Alpine's busybox, not Ubuntu's.

```bash
sudo unshare --pid --fork --mount --propagation private chroot rootfs /bin/sh -c 'mount -t proc proc /proc; head -2 /etc/os-release; uname -r; ps; wc -l /proc/mounts'
```

- **`chroot rootfs /bin/sh`** changes the root for path lookups: `/` now means `rootfs/`, so the absolute busybox symlinks resolve inside the rootfs.
- **Actual:** `NAME="Alpine Linux"`; kernel `7.0.0-34-generic` (the host's: a container has its own filesystem but shares the kernel); busybox `ps` shows PID 1 `sh -c …` and PID 5 `ps` (PIDs 2–4 were used by `mount`, `head`, `uname`: every external command consumes a PID); `/proc/mounts` has **1** line.
- **Surprise:** I expected dozens of lines in `/proc/mounts`. `/proc/self/mounts` only lists mounts reachable from the process's root directory, so after `chroot` the host mounts are hidden from it even though they are still attached to the namespace. Only the new `proc` (inside the rootfs) is shown.

## Step 12 — Same namespace, two views

```bash
sudo unshare --mount --propagation private sh -c 'echo "outside chroot: $(wc -l < /proc/mounts) mounts"; chroot rootfs /bin/sh -c "mount -t proc proc /proc; echo \"inside chroot:  \$(wc -l < /proc/mounts) mounts\""'
```

**Actual:** `outside chroot: 26 mounts`, `inside chroot: 1 mounts`. One mount namespace, one set of mounts in the kernel; only the process's root directory differs. `chroot` hides the host filesystem but does not detach it: all 26 mounts stay attached under the chrooted process, and a root process with the right syscalls can climb back out. `pivot_root` fixes this by swapping the root mount so the old root can be unmounted completely.

### Side quest — a rootfs from nothing (`tiny/`)

Any directory can become `/`; `chroot` does not care what Alpine is. The condition: the command you run must exist inside it, together with everything it depends on.

```bash
mkdir -p tiny/bin && cp /bin/bash tiny/bin/ && sudo chroot tiny /bin/bash -c 'echo hello'; ldd /bin/bash
```

**Actual:** `chroot: failed to run command '/bin/bash': No such file or directory`, although `tiny/bin/bash` exists. The missing file is the dynamic loader (`/lib64/ld-linux-x86-64.so.2`) that the kernel starts first; the error names `bash`, the problem is the loader. `ldd` listed `libtinfo.so.6`, `libc.so.6`, the loader, and `linux-vdso.so.1`, which has no path: the kernel maps it into every process, it never exists on disk.

```bash
cp --parents /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libc.so.6 /lib64/ld-linux-x86-64.so.2 tiny/ && sudo chroot tiny /bin/bash -c 'echo "hello from bash"; echo "/ contains:" /*; ls'; du -sh tiny
```

**Actual:** `hello from bash`; `/ contains: /bin /lib /lib64`; `ls: command not found`; `3.9M tiny`.

- `cp --parents` keeps full paths, so the loader lands where it will be looked up after `chroot`.
- `echo /*` lists `/` using bash's own globbing, no external program.
- **Lesson:** an image is literally the program plus everything it depends on. Anything not built into bash simply does not exist in `tiny/`; Alpine ships a full toolset in 8.7 MB. This is why statically linked binaries (e.g. Go) and distroless images exist: fewer dependencies, smaller and safer images.

## Step 13 — `pivot_root`: detach the old root

```bash
mkdir -p rootfs/.oldroot && sudo unshare --mount --pid --fork --propagation private sh -c 'mount --bind rootfs rootfs && cd rootfs && pivot_root . .oldroot && cd / && mount -t proc proc /proc && echo "before umount: $(wc -l < /proc/mounts) mounts" && umount -l /.oldroot && echo "after umount:  $(wc -l < /proc/mounts) mounts" && echo "/.oldroot contains: [$(ls -A /.oldroot)]" && head -1 /etc/os-release'
```

- **`mkdir -p rootfs/.oldroot`** as your user, before `sudo`: where `pivot_root` parks the old root; created unprivileged so no root-owned file is left in the rootfs.
- **`mount --bind rootfs rootfs`:** `pivot_root` requires the new root to be a mount point; binding the directory onto itself makes it one without changing its contents.
- **`--propagation private`:** `pivot_root` refuses to operate on shared mounts, since the change would otherwise propagate to the host (the link to steps 9–10).
- **`pivot_root . .oldroot`:** the rootfs becomes `/`, the old root moves to `/.oldroot`; every command after this is Alpine's.
- **Before umount** the host mounts are *visible*, because they now sit under `/.oldroot`, reachable from the new root.
- **`umount -l /.oldroot`:** lazy unmount detaches the whole old root with all its submounts at once. This is what `chroot` cannot do.

**Actual:** `before umount: 28 mounts`, `after umount: 2 mounts` (the new `/` and `proc`), `/.oldroot contains: []`, `NAME="Alpine Linux"`. The process has no path back to the host filesystem. Success criterion met: `ls /` shows Alpine, and the host is detached rather than hidden.

## Steps 14–15 — A real cgroup: how systemd runs Ollama

### Step 14 — Inspect Ollama's cgroup and `dmem`

```bash
cat /sys/fs/cgroup/cgroup.subtree_control; cat /proc/$(pgrep -o ollama)/cgroup; cat /sys/fs/cgroup/system.slice/ollama.service/{memory.current,memory.max,pids.current}; cat /sys/fs/cgroup/dmem.capacity 2>&1
```

- **`cgroup.subtree_control`** lists controllers *enabled* for children (vs `cgroup.controllers`: *available*). Controllers are enabled top-down, level by level; a child only gets `memory.max` etc. if its parent enables `memory`.
- **`/proc/<pid>/cgroup`** in v2 is one line, `0::/path`; the `0` and empty field are leftovers of v1's one-line-per-hierarchy format.
- **Actual:** root `subtree_control` has all controllers; Ollama is in `0::/system.slice/ollama.service`; `memory.current` 578744320 (≈552 MiB with no model loaded, including page cache charged to the cgroup); `memory.max` `max`; `pids.current` 18 (`pids` counts tasks, i.e. threads too).
- **`dmem.capacity` is empty:** the file exists but no regions are registered. With NVIDIA 580 open modules, VRAM cannot be limited through cgroups. Drivers opt in by calling `drmm_cgroup_register_region`; on this kernel only `xe` and `amdgpu` do (how to check: `docs/runbook.md`).

### Step 15 — The unit versus the cgroup files

```bash
systemctl cat ollama; systemctl show ollama -p Slice,ControlGroup,MemoryMax,TasksMax; cat /sys/fs/cgroup/system.slice/ollama.service/pids.max
```

- **There is no separate "cgroup config":** the unit file is the configuration; systemd creates `system.slice/ollama.service` and writes the limits into its files (`MemoryMax=8G` would become `8589934592` in `memory.max`).
- **Actual:** unit in `/etc/systemd/system/ollama.service` plus drop-in `override.conf` (`OLLAMA_HOST=0.0.0.0:11434`, an `ExecStartPre=+…` that waits up to 60 s for `nvidia-smi -L` to succeed). `MemoryMax=infinity`, `TasksMax=70833`, and `pids.max` = **70833**.
- **A limit nobody wrote:** systemd applies a default `TasksMax` to every service (a percentage of the system maximum) so one fork bomb cannot exhaust the machine. The same 70833 appeared as `Tasks: 1 (limit: 70833)` in `systemctl status nvidia-persistenced` during Prep.
- **`ExecStartPre=+`:** the `+` runs that command with full privileges, ignoring `User=ollama`. Here it waits for the GPUs at boot.
- **`WantedBy=default.target`** still works after `set-default multi-user.target`: `default.target` is an alias, and Ollama was active after the reboot.
- **Security note:** `OLLAMA_HOST=0.0.0.0` makes the unauthenticated Ollama API listen on all interfaces, but `ufw` (default deny incoming) only allows 11434/tcp on three Docker bridge interfaces (`br-…`) and from `172.18.0.0/16`; from the LAN only SSH is open. The bind to `0.0.0.0` is what lets containers (Ghostwheel) reach the host's Ollama via the bridge gateway, and the firewall keeps the LAN out. Follow-ups for Lab 0c: rules tied to `br-<id>` names break silently if a Docker network is recreated (pin network names/subnets in IaC); check for stale rules of deleted networks; see how ufw and Docker rules coexist underneath in nftables.

## Step 16/31 — Create a cgroup by hand

```bash
sudo mkdir /sys/fs/cgroup/lab0a && cat /sys/fs/cgroup/lab0a/cgroup.controllers && ls /sys/fs/cgroup/lab0a | wc -l && ls /sys/fs/cgroup/lab0a | grep -E '^(memory|pids|cpu)\.(max|current|events)$'
```

- **`mkdir` in cgroupfs creates a cgroup.** No special command: the filesystem is the interface, and the kernel fills the new directory with control files.
- **Actual:** `cgroup.controllers` matches the root's `subtree_control` (`cpuset cpu io memory hugetlb pids rdma misc dmem`); 86 files; the files used next: `cpu.max`, `memory.current`, `memory.events`, `memory.max`, `pids.current`, `pids.events`, `pids.max`.
- **Note:** creating a cgroup directly under the root, next to systemd's slices, is fine for learning; the production way is delegation (`systemd-run --scope`, `Delegate=yes`), covered in Lab 0b. Manually created cgroups do not survive a reboot (cgroupfs lives in memory), which is why systemd recreates its tree from unit files on every boot.

## Step 17/31 — Set the limits

```bash
( cd /sys/fs/cgroup/lab0a && echo 100M | sudo tee memory.max && echo 0 | sudo tee memory.swap.max && echo 20 | sudo tee pids.max && echo "50000 100000" | sudo tee cpu.max && echo "--- read back:" && cat memory.max memory.swap.max pids.max cpu.max ); swapon --show
```

- **`memory.max` 100M:** written with a suffix, read back in bytes (`104857600`).
- **`memory.swap.max` 0:** without it, a process hitting `memory.max` gets swapped out instead of OOM-killed: slow, but no kill. Z790 has an 8 GB `/swap.img`, so this matters here.
- **`pids.max` 20:** at most 20 tasks (processes and threads).
- **`cpu.max` `50000 100000`:** quota and period in microseconds, 50 ms of CPU per 100 ms = half a core. CFS bandwidth control, the same mechanism Kubernetes uses for `limits.cpu`.
- **`echo X | sudo tee file`, not `sudo echo X > file`:** the `>` redirection is done by your own shell before `sudo` starts, so it fails with Permission denied; `tee` opens the file as root.
- **`( … )`** runs in a subshell, so `cd` does not move your shell.
- **Actual:** read back `104857600`, `0`, `20`, `50000 100000`; `swapon --show` lists `/swap.img` 8G, 0B used.

## Step 18/31 — Move a process in and trigger an OOM kill

```bash
sudo sh -c 'echo $$ > /sys/fs/cgroup/lab0a/cgroup.procs; exec python3 -c "b = bytearray(200 * 1024**2); print(\"survived\")"'; echo "exit code: $?"; cat /sys/fs/cgroup/lab0a/memory.events; sudo dmesg | grep -i "memory cgroup" | tail -2
```

- **`echo $$ > cgroup.procs`:** moving a process into a cgroup is writing its PID into this file; children inherit the parent's cgroup.
- **`exec python3`** replaces `sh` in the same process (same PID), so Python is already inside the cgroup.
- **`bytearray(200 * 1024**2)`** allocates 200 MB of zeros, actually written, so the memory is really committed, not just reserved.

**Actual:** `Killed`, `exit code: 137` (128 + 9, SIGKILL: the OOM killer gives no chance to clean up). `memory.events`: `max 18`, `oom 1`, `oom_kill 1`, `oom_group_kill 0`. Kernel log: `Memory cgroup out of memory: Killed process 5462 (python3) total-vm:223152kB, anon-rss:101884kB, file-rss:6404kB`. Success criterion met.

- **`max 18`:** 18 times the cgroup hit its ceiling and the kernel tried to reclaim memory before giving up and killing.
- **`total-vm` ≈ 218 MB vs `anon-rss` ≈ 99.5 MB:** virtual size is what was requested, RSS is what was actually resident when the kill came, right at the 100 MB limit.
- **`oom_group_kill`:** with `memory.oom.group = 1` the kernel kills every process in the cgroup together instead of one; container runtimes use it so a container never survives half-dead.
- This `dmesg` line is what to look for in production when a container "just disappears".

## Step 19/31 — `pids.max` versus a controlled fork bomb

```bash
sudo -v && { sudo sh -c 'echo $$ > /sys/fs/cgroup/lab0a/cgroup.procs; for i in $(seq 30); do sleep 5 & done; wait' 2>&1 | sort | uniq -c & } ; sleep 1; echo "pids.current: $(cat /sys/fs/cgroup/lab0a/pids.current)"; wait; cat /sys/fs/cgroup/lab0a/pids.events
```

- **`sudo -v`** refreshes the sudo timestamp first, so the background job never stops waiting for a password.
- Inside, `sh` moves itself into `lab0a` and tries to start 30 background `sleep 5`. `sort | uniq -c` runs outside the cgroup (only the inner `sh` moved), so it is not limited.
- `pids.current` is read from the host shell after 1 s, because inside there is no room left even for `cat`.

**Expected:** `pids.current: 20`, 11 failed forks, `max 11`.

**Actual:** `pids.current: 19`, a single `sh: 0: Cannot fork`, `pids.events` `max 1`.

**Why the prediction was wrong:** a non-interactive `dash` aborts on the first failed fork. `sh` + 19 `sleep` reached the limit of 20; the 20th `sleep` fork was refused (`max 1`); `sh` exited, leaving 19 `sleep` processes, hence `pids.current: 19`. The job finished only when the sleeps did, because they still held the pipe to `sort`. A real fork bomb keeps retrying and would keep incrementing `max`; either way the cgroup stops at its ceiling instead of exhausting the machine, which is what systemd's default `TasksMax` does for every service.

## Step 20/31 — Remove the cgroup

```bash
cat /sys/fs/cgroup/lab0a/cgroup.procs; sudo rmdir /sys/fs/cgroup/lab0a && ls -d /sys/fs/cgroup/lab0a 2>&1
```

- A cgroup can only be removed when it has no processes (`cgroup.procs` empty); otherwise `rmdir` fails with `Device or resource busy`.
- **`rmdir`, not `rm -rf`:** the control files are a kernel interface and cannot be deleted one by one; `rmdir` on the empty cgroup removes them all.
- **Actual:** `cgroup.procs` empty; `ls: cannot access '/sys/fs/cgroup/lab0a': No such file or directory`. The same check goes into the cleanup of `minicontainer.sh`.

## Step 21/31 — Network namespace and a veth pair

```bash
sudo ip netns add lab0a && sudo ip link add veth-host type veth peer name veth-cont && sudo ip link set veth-cont netns lab0a && echo "--- host:" && ip -br link show veth-host && echo "--- inside lab0a:" && sudo ip netns exec lab0a ip -br link
```

- **`ip netns add`** creates a *named* network namespace pinned by a bind mount at `/run/netns/lab0a`, so it survives without processes (unlike `unshare --net`) and can be configured over several steps.
- **`veth`** is a virtual Ethernet cable with two ends; useful because the ends can live in different namespaces. One end is moved into `lab0a`.
- **`ip netns exec`** runs a command inside an existing namespace.
- **Actual:** host `veth-host@if7 DOWN`; inside only `lo DOWN` and `veth-cont@if8 DOWN`. `@ifN` is the peer's interface index in the *other* namespace (indexes are per namespace). Inside there is no LAN interface, no Docker bridges: a new network namespace starts with an empty stack (own interfaces, routes, firewall rules, ports); even loopback is down.
- Docker does exactly this per container; its `vethXXXX` ends are visible on the host attached to Docker bridges.

## Step 22/31 — Addresses, link up, ping

```bash
sudo ip addr add 10.200.0.1/24 dev veth-host && sudo ip link set veth-host up && sudo ip netns exec lab0a sh -c 'ip addr add 10.200.0.2/24 dev veth-cont && ip link set veth-cont up && ip link set lo up && ping -c 3 10.200.0.1; echo "--- routes:"; ip route; echo "--- internet:"; ping -c 1 -W 1 1.1.1.1'
```

**Actual:** 3/3 replies from `10.200.0.1` (0.148, 0.077, 0.079 ms); a single route `10.200.0.0/24 dev veth-cont proto kernel scope link src 10.200.0.2`; `ping 1.1.1.1` → `connect: Network is unreachable`. Success criterion met.

- **First ping slower (0.148 ms vs \~0.078):** it includes ARP resolution of the host's MAC; later packets reuse the neighbour entry. Sub-0.1 ms because packets never leave the kernel.
- **ufw** (default deny incoming) still answers ICMP echo, so the ping passes; anything else from the namespace to the host would be blocked.
- **No default route:** the kernel does not even try to send to the internet. Internet access needs a default route *and* NAT/forwarding on the host, which collides with Docker's `FORWARD` policy and ufw's `deny (routed)`: deferred to Lab 0c.
- **`ip netns exec` changes only the network namespace:** `sh`, `ip`, `ping` and the filesystem are the host's. Namespaces are independent and compose freely.

## Step 23/31 — Network cleanup

NAT to the internet (originally step 23) is deferred to Lab 0c: it needs changes to Docker's `FORWARD DROP`, ufw's `deny (routed)` and a masquerade rule on a host that runs Ghostwheel's containers.

```bash
sudo ip netns del lab0a && ip -br link show veth-host 2>&1; ls -A /run/netns/
```

**Actual:** `Device "veth-host" does not exist.`; `/run/netns/` empty. Deleting the namespace (no processes left) destroyed `veth-cont`, and a veth pair cannot exist with one end, so the kernel removed `veth-host` too. One deletion cleans up the whole cable.

## Step 24/32 — User namespace as an unprivileged user (blocked)

```bash
unshare --user --map-root-user sh -c 'id; cat /proc/self/uid_map'; echo "exit: $?"; sudo dmesg | grep -i apparmor | tail -3
```

- **The idea:** inside, the process is root (UID 0); outside, it is your own user (UID 1000 here). Root inside only applies to the namespace's own resources. This is how rootless Podman works, and how everything done so far with `sudo` could be done without it.
- **`--map-root-user`** writes the mapping "0 inside = 1000 outside" into `/proc/self/uid_map`.

**Actual:** `unshare: write failed /proc/self/uid_map: Operation not permitted`, `exit: 1`. Kernel audit log:

- `apparmor="AUDIT" operation="userns_create" … info="Userns create - transitioning profile" profile="unconfined" … target="unprivileged_userns"`: creating the namespace is *allowed*, but the process is immediately moved into the restrictive `unprivileged_userns` profile.
- `apparmor="DENIED" operation="capable" profile="unprivileged_userns" … capability=21 capname="sys_admin"`: inside that profile, the capability needed to set up the mapping is denied.

**Why Ubuntu does this:** user namespaces give an unprivileged user "root" over large parts of kernel code (network stack, filesystems, netfilter), the path of many recent privilege-escalation bugs. Ubuntu allows them only for programs with an explicit AppArmor profile.

## Step 25/32 — A dedicated `unshare` copy with its own AppArmor profile

Not globally: `sysctl kernel.apparmor_restrict_unprivileged_userns=0` would open user namespaces to every program, and a profile for `/usr/bin/unshare` would be nearly the same, since `unshare` is a generic launcher. A lab-only copy limits the effect to one visible, removable binary.

```bash
sudo install -m 0755 -o root -g root /usr/bin/unshare /usr/local/bin/lab0a-unshare && sudo tee /etc/apparmor.d/lab0a-unshare >/dev/null <<'EOF' && sudo apparmor_parser -r /etc/apparmor.d/lab0a-unshare && sudo aa-status | grep -A1 -i lab0a
abi <abi/4.0>,
include <tunables/global>

profile lab0a-unshare /usr/local/bin/lab0a-unshare flags=(unconfined) {
  userns,
}
EOF
```

- **`install -o root -g root -m 0755`:** root-owned and not writable by others, so nobody can swap the file for something that inherits the permission.
- **The profile attaches by path.** `flags=(unconfined)` restricts nothing else; `userns,` is the only addition, so AppArmor no longer moves the process into `unprivileged_userns`.
- **`apparmor_parser -r`** loads the profile into the kernel immediately.
- **Trade-off (documented, not hidden):** any user on this host can use `lab0a-unshare`; acceptable on a single-user lab server. Ubuntu uses the same model for its own programs that need user namespaces; Lab 0f does the same for bubblewrap.
- **Actual:** `aa-status` lists `lab0a-unshare`.
- **Context:** in 2025 Qualys published three bypasses of this restriction (via `aa-exec`, busybox's permissive profile, and `LD_PRELOAD` into programs with permissive profiles). Canonical treats them as defense-in-depth limits; mitigations include `kernel.apparmor_restrict_unprivileged_unconfined=1` and disabling broad profiles. The restriction is a tripwire that leaves audit records, not a wall; the real defense against kernel exploits is a patched kernel. Follow-up for Lab 0c/11: check those settings on this host.

## Step 26/32 — Rootless test

```bash
lab0a-unshare --user --map-root-user sh -c 'id; echo "uid_map: $(cat /proc/self/uid_map)"; grep CapEff /proc/self/status; touch /etc/lab0a-test'; echo "exit: $?"
```

**Actual:** `uid=0(root) gid=0(root) groups=0(root),65534(nogroup)`; `uid_map: 0 1000 1`; `CapEff: 000001ffffffffff`; `touch: cannot touch '/etc/lab0a-test': Permission denied`; `exit: 1`.

- Root inside, with **all** capabilities including `CAP_SYS_ADMIN` (denied in step 24).
- Host groups with no mapping inside appear as `65534(nogroup)`.
- **`touch /etc` fails anyway:** `/etc` belongs to the real root, and the kernel checks access against the UID *outside* (1000). Root in a user namespace grants nothing your own user did not already have on host resources.

## Step 27/32 — Assemble `scripts/minicontainer.sh`

The script lives in the repo (`scripts/`), not in `work/`: it is code, reused as variant A of Lab 11. 81 lines; full source in the repo. Structure:

- **Pre-checks:** root, Alpine rootfs present (checks `bin/busybox`, not `bin/sh`: the absolute symlink from step 4 would resolve on the host), no stale cgroup or netns.
- **`cleanup` on `trap EXIT`:** `ip netns del` (removes both veth ends), then `rmdir` the cgroup with a short retry loop, since it can only go once the last process has exited. Runs on normal exit, error and Ctrl+C.
- **Block 1, cgroup** (steps 16–17): `memory.max`, `memory.swap.max = 0`, `pids.max`, `cpu.max`.
- **Block 2, network** (steps 21–22): netns, veth pair, container end renamed to `eth0` as Docker does.
- **Block 3, `INNER`** (steps 8 and 13), runs as PID 1: hostname, bind mount, `pivot_root`, fresh `/proc`, `umount -l /.oldroot`, then `exec env -i … /bin/sh` (Alpine's shell with a clean environment, nothing inherited from the host).
- **Block 4, launch** (steps 6–7, 18): a subshell writes its own PID into `cgroup.procs` first so everything after inherits the cgroup, then `ip netns exec` enters the network namespace and `unshare --uts --pid --mount --ipc --cgroup --fork --propagation private` creates the rest.
- **New compared to the individual steps:** `--ipc` (isolates shared memory and message queues) and `--cgroup` (inside, `/proc/self/cgroup` shows `0::/` instead of `0::/lab0a`; created *after* the move so `lab0a` becomes the root seen inside).

## Step 28/32 — First run, checking the success criteria

```bash
sudo ./minicontainer.sh sh -c 'echo "hostname: $(hostname)"; head -1 /etc/os-release; echo "--- ps:"; ps; echo "--- cgroup: $(cat /proc/self/cgroup)"; echo "--- mounts: $(wc -l < /proc/mounts)"; ip -br addr; ping -c 2 10.200.0.1'; echo "exit: $?"
```

**Actual:** `hostname: lab0a`; `NAME="Alpine Linux"`; `ps` shows PID 1 `sh -c …` and PID 11 `ps` (2–10 were consumed by the command substitutions before it); `cgroup: 0::/`; `mounts: 2`; ping 2/2 (0.144, 0.081 ms); `exit: 0`.

- **Mistake:** `ip -br addr` printed BusyBox's usage text. `-br` (brief) is an iproute2 option; Alpine's `ip` is a BusyBox applet with fewer options. Inside the container, the tools are Alpine's, not Ubuntu's. Re-checked with plain `ip addr` in step 29.
- The container still exited 0 because `sh -c` without `set -e` continues after a failed command, and the last command (`ping`) succeeded.

## Step 29/32 — Interactive container, viewed from the host

**Window 1:** `sudo ./minicontainer.sh` gives the prompt `[lab0a] #` (Alpine's shell as PID 1). Inside, `ip addr show eth0` → `11: eth0@if12 … state UP`, `inet 10.200.0.2/24`; `ping 10.200.0.1` 2/2. Interface indexes differ from step 21 because every run creates a new namespace. `M-DOWN` appears to be cosmetic (the peer, index 12, lives in another namespace); traffic works.

**Window 2,** while the container runs:

```bash
P=$(sudo ip netns pids lab0a | tail -1); echo "container PID 1 on host: $P"; sudo lsns -p "$P" -o NS,TYPE,PID,COMMAND; echo "--- host (PID 1):"; sudo lsns -p 1 -o NS,TYPE,PID,COMMAND
```

- `ip netns pids lab0a` lists the processes in the container's network namespace; the last one is the shell (PID 1 inside, an ordinary PID outside).
- `lsns -p` shows all 8 namespace types of a process; the `PID` column is the lowest PID in each namespace.

**Actual:** container shell is PID 16244 on the host. `net`, `mnt`, `uts`, `ipc`, `cgroup` have new inodes (4026533011, 4026533221–23, 4026533225) with lowest PID **16242** (the `unshare` parent); `pid` has a new inode (4026533224) with lowest PID **16244** (the shell). `time` (4026531834) and `user` (4026531837) are the host's, shared with `/sbin/init`. The host's eight namespaces are the fixed constants 4026531832–4026531839. Last success criterion met.

- **Step 6 confirmed visually:** `unshare()` moves the caller into new uts/mnt/net/ipc/cgroup namespaces immediately, so the parent `unshare` (16242) is in them; the PID namespace applies only to children, so the parent stays in the host's PID namespace and only the forked shell (16244) is in the new one.
- **The most important line: `user` is shared with the host.** The container is not in a user namespace, so root inside is the real root of the host with all capabilities. Escaping this container means root on Z790. That is why steps 24–26 and rootless Podman matter, and where Lab 11 starts.
- **Known gaps, deliberately left for Lab 11 (hardened variant A):** no `/dev` (not even `/dev/null`), no `/tmp` or `/sys`, no capability dropping, no seccomp, no user namespace.

## Step 30/33 — Exit and verify cleanup

In window 1, `exit` the container, then:

```bash
echo "exit: $?"; ls -d /sys/fs/cgroup/lab0a /run/netns/lab0a 2>&1; ip -br link show lab0a-h 2>&1; findmnt | grep -c lab0a
```

**Actual:** `exit: 0`; cgroup and netns: `No such file or directory`; `Device "lab0a-h" does not exist.`; `0` mounts. The `trap` removed the cgroup and the netns (which took the veth pair with it); the bind mount and `/proc` lived only in the container's mount namespace and vanished with it. All six success criteria are met.

## Step 31/33 — The same view of a Docker container

Docker is already running on Z790, so it is used for the comparison instead of installing Podman; rootless Podman belongs to Lab 11, where the user namespace is the topic.

```bash
sudo docker run -d --rm --name lab0a-cmp alpine:3.24 sleep 120 >/dev/null && P=$(sudo docker inspect -f '{{.State.Pid}}' lab0a-cmp) && echo "docker container PID on host: $P" && sudo lsns -p "$P" -o NS,TYPE,PID,COMMAND; sudo docker stop -t 1 lab0a-cmp >/dev/null
```

**Actual:** image pulled (`Digest: sha256:294b683c…`); container PID 17445. New `mnt`, `uts`, `ipc`, `pid`, `cgroup`, `net` **and `time`** namespaces, all with lowest PID 17445 (`sleep 120`); only `user` (4026531837) is shared with the host.

- **Same core model as `minicontainer.sh`:** six new namespaces, and the user namespace shared. Root in a default Docker container is root on the host (`userns-remap` exists but is off by default).
- **Cleaner process model:** every namespace starts at the container's own process. runc creates the process directly in all new namespaces (`clone()` with all flags) and the parent stays entirely outside; our script leaves the `unshare` parent inside five of them.
- **Wrong prediction: Docker also created a new `time` namespace.** A time namespace gives per-container offsets for `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` (used e.g. by checkpoint/restore); it does not change wall-clock time. Checked afterwards (see `results/lab0a.md`): Docker 29.8.0 with its default configuration lists `time` in the OCI spec it hands to runc, with zero offsets.
- **Inode numbers are recycled:** Docker's `mnt` 4026533011 is the number our `net` namespace had in step 29, and its `time` 4026533223 was our `ipc`. A namespace inode identifies a namespace only while it is alive.
- **Tag vs digest:** `alpine:3.24` is a mutable tag (it moves with each 3.24.x); the digest is the immutable identity. Pinning by digest (`alpine:3.24@sha256:…`) is the image equivalent of the pinned download path in step 3.

## Step 32/33 — Start-up time: `minicontainer.sh` versus Docker

Run from `~/ai-homelab/scripts` (relative path):

```bash
sudo -v && time (for i in 1 2 3 4 5; do sudo ./minicontainer.sh true; done) && time (for i in 1 2 3 4 5; do sudo docker run --rm alpine:3.24 true; done)
```

- Five runs each to smooth noise; `true` exits immediately, so only create + destroy is measured. `sudo -v` first keeps password entry out of the measurement; both pay the same `sudo` cost.

|  | 5 runs (real) | Per run | user + sys (5 runs) |
| --- | --- | --- | --- |
| `minicontainer.sh` | 0.619 s | \~124 ms | 0.022 + 0.047 s |
| `docker run --rm` | 2.589 s | \~518 ms | 0.025 + 0.042 s |

- **About 4× faster,** but my estimate of "tens of milliseconds" was low: \~124 ms per run. CPU time is tiny (\~14 ms per run), so most of it is waiting on the kernel: network namespace and veth setup and teardown, mount namespace work. Where exactly it goes is an open question for profiling in Lab 11.
- **Docker's `user`/`sys` is just as tiny, which is misleading:** `time` only counts the client and its children. The real work happens in `dockerd`, `containerd` and `runc`, which are not children of the shell. Measuring a client-server system with `time` shows latency, not cost.
- **The difference does not make Docker slow or bad.** It pays for things the script does not do: layered images shared between containers, overlayfs, bridge networking with NAT to the internet, logging, restart policies, an API. The script's number is the cost of the kernel primitives alone.

## Step 33/33 — Write-up

- `results/lab0a.md`: goal, what was done, measurements, surprises, mistakes and dead ends, open questions, follow-ups.
- `docs/runbook.md`: section "Lab 0a: namespaces, cgroups, containers" with the commands worth keeping.
- `ansible/roles/lab_tools` + `ansible/lab0a.yml`: the dedicated `lab0a-unshare` copy and its AppArmor profile as code. Applied with Ansible in Lab 0g (`ansible/site.yml`). The copy does not receive util-linux security updates, so the role must be re-run after upgrades, or removed when no longer needed.
- `scripts/minicontainer.sh`, `chmod 755` (not group-writable: it runs as root).
- This guide as `docs/guides/lab0a.md`.

**All six success criteria met.** Known gaps of `minicontainer.sh` (no `/dev`, `/tmp`, `/sys`, capability dropping, seccomp or user namespace) are the starting point of Lab 11's hardened variant A.

## Gotchas and notes

- **`cd` inside an `&&` chain persists.** `mkdir -p ~/ai-homelab/work/lab0a && cd ~/ai-homelab/work/lab0a && …` leaves the shell in that directory; check the prompt before the next command.
- **AppArmor and user namespaces.** Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns = 1`. The same wall appears in the rootless step and in Claude Code's bubblewrap sandbox (Lab 0f); solve it once, per binary.
- **`systemctl is-active` cannot tell "stopped" from "not installed".** Both print `inactive`.
- **Absolute symlinks in the rootfs** only resolve correctly after the root changes.
- **Pin versions, read metadata.** Use `latest-*` only to discover; download by exact version.
- **Checksum ≠ signature.** Integrity from the same server, authenticity needs the GPG signature (Lab 11).
- **Docker on the same host** owns `172.17.0.0/16` and sets `FORWARD` to `DROP`; plan subnets and NAT around it.
