# Prep — Headless Z790 + nvidia-persistenced

Date: 2026-10-07 · Ubuntu 24.04, kernel 7.0.0-34-generic (HWE), NVIDIA 580.173.02 (open kernel modules), 2× RTX 5060 Ti

## Goal

Boot the server without a graphical session, keep both GPUs fully available for compute, enable persistence mode. Establish a baseline before Lab 1.

## What I did

1. "Before" snapshot: default target, display manager, lspci, nvidia-smi (display_active, VRAM, power, P-state, processes).
2. Found there is no graphical session at all, so enabling the iGPU in BIOS became optional rather than required.
3. Found nvidia-persistenced running with `--no-persistence-mode`. Added a drop-in `/etc/systemd/system/nvidia-persistenced.service.d/override.conf` that resets and replaces `ExecStart`.
4. Tested whether a power limit survives with no persistence and no clients (170 W, 30+ s).
5. `systemctl set-default multi-user.target`.
6. Snapshot of KMS state: modeset/fbdev values and which file sets them.
7. Reboot and cold-boot verification.

## Measurements

| Metric | GPU0 (PCIe 5.0 x8, CPU) | GPU1 (PCIe 4.0 x4, chipset) |
|---|---|---|
| Idle VRAM, no clients | 2 MiB | 2 MiB |
| Idle power before persistence (2 readings) | 9.52 / 9.85 W | 8.96 / 9.10 W |
| Idle power after persistence (mean of 10) | 9.84 W (9.76–9.92) | 9.17 W (9.14–9.21) |

- `nvidia-smi -L` with no persistence and no clients: ~40 ms; full `nvidia-smi`: ~75 ms.
- A 170 W power limit on GPU1 survived 30+ s with no persistence and no clients.
- After reboot: `multi-user.target`, 0 failed units, persistence Enabled on both GPUs, modeset=Y, fbdev=Y.

## What surprised me

- The hypothesis "the GPUs are being used for display" was false at the first measurement: display_active Disabled, 2 MiB VRAM, no Xorg. Measuring first saved a pointless trip into the BIOS.
- nvidia-persistenced was active but running with `--no-persistence-mode`, so persistence was Disabled. A running service is not the same as the intended effect: verify the result, not the process.
- The unit is static (no `[Install]` section) and is pulled in by `sys-bus-pci-drivers-nvidia.device` via udev, not by being enabled.
- On this driver, missing persistence had no visible cost in time (75 ms) and did not reset the power limit within 30+ s.
- Persistence costs nothing measurable at idle (difference ≤ 0.2 W, within noise).
- GPU0 consistently draws ~0.7 W more than GPU1 at idle, with no monitor attached for weeks.
- `/proc/fb` was empty despite fbdev=Y: DRM defers creating the framebuffer until an output is connected.
- `nvidia_drm` parameters under `/sys` are readable only by root.
- Two modprobe files set modeset=1: the package's (`nvidia-kernel-common-580`) and my manual `nvidia-kms.conf`, which is now redundant.

## Mistakes and dead ends

- Expected `nvidia-smi` without persistence to be slow (hundreds of ms or more). It was not; the hypothesis failed.
- Suspected a process was holding `/dev/nvidia*` open; `fuser` showed nothing.
- Copied command output before `sleep 30` had finished.
- The command from my old notes (`cat /sys/module/nvidia_drm/parameters/modeset`) fails with Permission denied without sudo.

## Open questions

- Why does GPU0 draw ~0.7 W more than GPU1 at idle: PCIe 5.0 x8 vs 4.0 x4, boot VGA device, silicon variance? Test in Lab 1 (`nvidia-smi -q -d PCIE` at idle, possibly swap slots).
- How long without clients (if ever) before the driver deinitializes the GPUs, and why is init so cheap?
- What does "NUMA memory onlined" in the persistenced log mean for these cards?
- Why was modeset N on the original install?
- The iGPU (UHD 770) is disabled in BIOS; enabling it as an emergency console is optional, as a separate step with its own reboot.
- HWE kernel: pin the kernel or only the driver? Decide in Lab 1.

## Follow-ups for later labs

- Role `nvidia_open`: persistenced drop-in; own modprobe file named to sort last (`zz-homelab-nvidia.conf`, not `99-`, since digits sort before letters); `update-initramfs -u` handler; remove the manual `nvidia-kms.conf`; oneshot unit that sets power limits at boot (`-pl` does not survive a reboot).
- Role `common`: `multi-user.target`.
- Principle: one change per reboot.
