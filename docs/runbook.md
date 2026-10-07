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
