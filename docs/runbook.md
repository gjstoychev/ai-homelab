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
