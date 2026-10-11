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
