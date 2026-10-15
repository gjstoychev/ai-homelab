# Runbook

A collection of useful commands, grouped by lab.

## Prep: NVIDIA and headless

GPU state snapshot:

```bash
systemctl get-default; nvidia-smi --query-gpu=index,display_active,memory.used,power.draw,pstate,persistence_mode --format=csv
```

Idle power, 10 samples:

```bash
timeout 30 nvidia-smi --query-gpu=index,power.draw,pstate --format=csv,noheader -l 3
```

Which processes hold the GPU devices:

```bash
sudo fuser -v /dev/nvidia*
```

What a unit actually runs and what pulls it in:

```bash
systemctl cat <unit>; systemctl list-dependencies --reverse <unit> --plain
```

Persistence drop-in (the empty `ExecStart=` resets the list and is required):

```bash
sudo mkdir -p /etc/systemd/system/nvidia-persistenced.service.d && printf '[Service]\nExecStart=\nExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose\n' | sudo tee /etc/systemd/system/nvidia-persistenced.service.d/override.conf && sudo systemctl daemon-reload && sudo systemctl restart nvidia-persistenced
```

NVIDIA KMS — black screen right after the login prompt (modeset=N). Fix: `options nvidia_drm modeset=1` in `modprobe.d`, then `sudo update-initramfs -u` and reboot. Verify (requires root):

```bash
sudo grep -H . /sys/module/nvidia_drm/parameters/{modeset,fbdev}
```

Which package owns a config file:

```bash
dpkg -S <path>
```

## Lab 0a: namespaces, cgroups, containers

Which namespaces a process is in:

```bash
sudo lsns -p <pid> -o NS,TYPE,PID,COMMAND
```

Namespace identifier of the current process:

```bash
readlink /proc/self/ns/<type>
```

Run a command with its own PID namespace and /proc:

```bash
sudo unshare --pid --fork --mount-proc <cmd>
```

Which cgroup a process is in:

```bash
cat /proc/<pid>/cgroup
```

Effective systemd limits of a unit:

```bash
systemctl show <unit> -p ControlGroup,MemoryMax,TasksMax
```

Write to a cgroup file as root:

```bash
echo <value> | sudo tee /sys/fs/cgroup/<cg>/<file>
```

OOM and limit counters:

```bash
cat /sys/fs/cgroup/<cg>/memory.events /sys/fs/cgroup/<cg>/pids.events
```

Kernel OOM messages:

```bash
sudo dmesg | grep -i "memory cgroup"
```

Processes in a named network namespace:

```bash
sudo ip netns pids <name>
```

AppArmor denials:

```bash
sudo dmesg | grep -i apparmor
```

Mount propagation of a mount:

```bash
findmnt -o TARGET,PROPAGATION <path>
```

Shared libraries a binary needs:

```bash
ldd <binary>
```

Versions of the Docker stack (engine, containerd, runc):

```bash
docker version --format '{{range .Server.Components}}{{.Name}} {{.Version}}{{"\n"}}{{end}}'
```

Namespaces Docker requests for a running container (its OCI spec):

```bash
ID=$(sudo docker inspect -f '{{.Id}}' <container>); sudo jq -c '[.linux.namespaces[].type]' "$(sudo find /run/containerd -name config.json -path "*$ID*")"
```

Time namespace offsets of a process:

```bash
sudo cat /proc/<pid>/timens_offsets
```

GPU kernel modules that use the dmem cgroup controller:

```bash
K=/lib/modules/$(uname -r); for m in $(find $K/kernel/drivers/gpu $K/updates -name '*.ko*'); do zstdcat "$m" 2>/dev/null | grep -aqE 'drmm_cgroup_register_region|dmem_cgroup' && echo "${m#$K/}"; done
```

Qualys aa-exec bypass check (should fail when the restriction is complete):

```bash
sysctl kernel.apparmor_restrict_unprivileged_unconfined; aa-exec -p trinity -- unshare --user --map-root-user id -u
```

## Lab 0g: Ansible

All Ansible commands run from `<repo>/ansible` (that is where `ansible.cfg` is read).

Effective SSH settings for a host, without connecting:

```bash
ssh -G <host> | grep -E '^(hostname|user|port|identityfile|identitiesonly) '
```

Non-interactive SSH test, the way Ansible connects:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 <host> 'hostname; python3 --version'
```

Settings that differ from the defaults, with their source:

```bash
ANSIBLE_PAGER=cat ansible-config dump --only-changed
```

Inventory as Ansible sees it; variables of one host:

```bash
ansible-inventory --graph; ansible-inventory --host <host>
```

Transport check (SSH, module copy, Python) and become check:

```bash
ansible <host> -m ansible.builtin.ping; ansible <host> -m ansible.builtin.command -a id --become
```

Dry run, then the real run, of everything for one host:

```bash
ansible-playbook site.yml --limit <host> --check --diff; ansible-playbook site.yml --limit <host> --diff
```

Exact package versions in the Ansible venv:

```bash
pipx runpip ansible-core freeze
```

Add a tool to the Ansible venv (uses the same ansible-core):

```bash
pipx inject ansible-core '<package>==<version>' --include-apps
```

Lint, showing what was checked:

```bash
ansible-lint -v
```

Running value of a sysctl (not the file):

```bash
sysctl <key>
```

## Lab 0f: Claude Code sandbox

Versions offered by Claude Code's apt repository (stable channel), and release date of one version:

```bash
curl -fsS https://downloads.claude.ai/claude-code/apt/stable/dists/stable/main/binary-amd64/Packages | grep '^Version:'
curl -fsS https://registry.npmjs.org/@anthropic-ai/claude-code | python3 -I -c 'import json,sys; t=json.load(sys.stdin)["time"]; print(t["<x.y.z>"])'
```

Fingerprint of a downloaded signing key, without touching your keyring:

```bash
d=$(mktemp -d); curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$d/k.asc"; gpg --homedir "$d" --show-keys --with-fingerprint "$d/k.asc"
```

Installed version and apt pin:

```bash
apt-cache policy claude-code | head -8
```

Installation and update diagnostics (no session started):

```bash
claude doctor
```

Is a command running inside the sandbox? (AppArmor label of the bwrap copy, proxy variables):

```bash
cat /proc/self/attr/current; echo; env | grep -iE '^(https?|all)_proxy=' || echo "(no proxy vars)"
```

Privileges of a process (capabilities, no_new_privs, seccomp):

```bash
grep -E '^(NoNewPrivs|Seccomp|CapEff|CapBnd)' /proc/self/status
```

Does bwrap work under the userns restriction? (copy vs system binary):

```bash
claude-bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all --die-with-parent id; bwrap --ro-bind / / --unshare-all --die-with-parent id
```

Parse an AppArmor profile without loading it (no root):

```bash
apparmor_parser -Q -K -I /etc/apparmor.d <file>
```

Ansible inside Claude Code's sandbox (home is read-only):

```bash
export ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp"
```



From another terminal: process tree, namespaces and bwrap arguments of a running sandboxed command (proxy URLs filtered out, they carry a password):

```bash
p=$(pgrep -n -f '<marker>'); ps -o pid,ppid,comm,args --forest -s $(ps -o sid= -p $p) | cut -c1-150; lsns -p $p
tr '\0' '\n' < /proc/$(pgrep -n -x claude-bwrap)/cmdline | grep -E '^--' | sort | uniq -c | sort -rn
```

AppArmor profiles loaded in the kernel (root):

```bash
sudo grep claude-bwrap /sys/kernel/security/apparmor/profiles
```

Headless check that the sandbox works (refuses to start without it):

```bash
claude -p 'Run: echo sandbox-ok'; echo "exit=$?"
```

## Lab 0b: systemd

Ad-hoc memory limit on any command (transient scope; `--expand-environment=no` passes `$` to the shell verbatim):

```bash
sudo systemd-run --scope --expand-environment=no -p MemoryMax=100M -p MemorySwapMax=0 -p OOMPolicy=continue sh -c '<cmd>; cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.events'
```

What systemd logged about a unit (including transient scopes):

```bash
journalctl -b --no-pager -u <unit>
```

Exposure score of a unit, summary and full report:

```bash
systemd-analyze security <unit> --no-pager
```

A unit and its drop-ins without D-Bus (e.g. from a sandbox):

```bash
cat /etc/systemd/system/<unit> /etc/systemd/system/<unit>.d/*.conf
```

Which settings systemd actually loaded (the running state, not the file):

```bash
systemctl show <unit> --no-pager -p ActiveState,NRestarts,DropInPaths,MemoryMax,MemorySwapMax,CPUQuotaPerSecUSec,TasksMax
```

Exposure score, only what is still failed:

```bash
systemd-analyze security <unit> --no-pager | grep '✗'
```

What a system call group contains:

```bash
systemd-analyze syscall-filter @system-service
```

A service's memory: total, kinds, events, swap (cgroup files are world-readable):

```bash
cg=/sys/fs/cgroup/system.slice/<unit>
cat $cg/memory.current $cg/memory.swap.current
grep -E '^(anon|file|file_mapped|shmem) ' $cg/memory.stat
cat $cg/memory.events
```

Anonymous vs mapped-file memory of each process in a service (root):

```bash
cg=/sys/fs/cgroup/system.slice/<unit>
sudo sh -c "for p in \$(cat $cg/cgroup.procs); do echo \"== \$(cat /proc/\$p/comm)\"; grep -E '^(Rss|Pss_Anon|Pss_File)' /proc/\$p/smaps_rollup; done"
```

Device nodes a service's processes have open (root):

```bash
sudo sh -c "for p in \$(cat /sys/fs/cgroup/system.slice/<unit>/cgroup.procs); do ls -l /proc/\$p/fd | grep -o '/dev/.*'; done" | sort | uniq -c
```

Test a cgroup-level limit (memory, IP filter) with a process moved into a service's cgroup (root; it gets the cgroup's limits, not the service's seccomp filter or namespaces):

```bash
sudo sh -c "echo \$\$ > /sys/fs/cgroup/system.slice/<unit>/cgroup.procs; exec <cmd>"
```

Test device rules in a transient service:

```bash
sudo systemd-run --wait --pipe --quiet -p User=<user> -p DevicePolicy=closed -p DeviceAllow='char-nvidia rw' sh -c '( : < /dev/<node> ) && echo opened'
```

Temporary property change, and its undo (never `systemctl revert`: it removes every drop-in of the unit):

```bash
sudo systemctl set-property --runtime <unit> MemoryMax=4G
sudo systemctl set-property --runtime <unit> MemoryMax=<original>
sudo rm /run/systemd/system.control/<unit>.d/50-MemoryMax.conf && sudo systemctl daemon-reload
```

A temporary drop-in for trying a directive (gone after a reboot):

```bash
sudo mkdir -p /run/systemd/system/<unit>.d
printf '[Service]\n<Directive>=<value>\n' | sudo tee /run/systemd/system/<unit>.d/trial.conf
sudo systemctl daemon-reload && sudo systemctl restart <unit>
```

A unit stopped by its start limit:

```bash
journalctl -u <unit> -n 40 --no-pager | grep -E 'Scheduled restart|repeated too quickly'
sudo systemctl reset-failed <unit> && sudo systemctl start <unit>
```

Order of events at boot, with sub-second timestamps:

```bash
journalctl -b -o short-precise --no-pager | grep -E '<pattern>'
```

Ollama: which cards it found, how it loaded a model, and the buffer sizes llama.cpp chose:

```bash
journalctl -u ollama -n 300 --no-pager | grep -E 'inference compute|load_mode =|disabling mmap|KV buffer size|model buffer size|n_threads'
```

Ollama: load a model without generating, and with request options:

```bash
curl -s localhost:11434/api/generate -d '{"model":"<model>","keep_alive":"10m","options":{"num_ctx":32768,"num_gpu":0}}'
```
