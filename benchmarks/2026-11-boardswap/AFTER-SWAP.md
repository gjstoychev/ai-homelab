# After the board swap: checklist and re-run

The "before" numbers cannot be recreated, so after the swap everything runs
the same way, with the same images, scripts and models, into `after/`. Work
through it one item at a time, as before; compare every output with the
expectation before going on. Sources: `~/ai-homelab/work/preswap-baseline.txt`,
`journal.md`.

## A. Before shutting down the old board

- [x] **Record platform settings** (step 20a, writes `before/20-platform.txt`;
      done 2026-11-19 21:15 UTC; after the swap run it again with
      `after/20-platform.txt`):
      BIOS, RAM speed, CPU power limits, governor, microcode, Resizable BAR,
      image IDs. Serial numbers are filtered out.

```bash
cd ~/benchmarks/2026-11-boardswap
I=(local/llama.cpp:b12464-nccl local/nvbandwidth:cuda13.0.0)
I+=(ollama/ollama:0.32.14 nvidia/cuda:13.0.0-base-ubuntu24.04)
{
  date -u
  sudo dmidecode -t bios -t baseboard |
    grep -E 'Vendor|Manufacturer|Product Name|Version|Release Date'
  sudo dmidecode -t memory |
    grep -E '^\s+(Locator|Size|Speed|Configured Memory Speed|Part Number):' |
    grep -v 'No Module'
  grep . /sys/class/powercap/intel-rapl:0/constraint_*_power_limit_uw
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  grep -m1 microcode /proc/cpuinfo
  nvidia-smi -q -d MEMORY | grep -A3 'BAR1'
  for i in "${I[@]}"; do
    sudo docker image inspect "$i" --format "$i {{.Id}} {{.RepoDigests}}"
  done
} 2>&1 | tee before/20-platform.txt
```

- [ ] No `apt upgrade` (91 packages pending since step 6d) until all "after"
      runs are done: kernel, driver, Docker and toolkit must stay identical.
      This includes `unattended-upgrades`: it installed kernel 7.0.0-43 on
      2026-11-21 (missed in the first version of this checklist). User's
      decision: stay on 7.0.0-43, keep auto-updates on; Claude checks for
      changes before every measurement step.
- [ ] Keep the Docker images (no `docker system prune`). IDs recorded in
      `before/20-platform.txt`: `local/llama.cpp:b12464-nccl` =
      `sha256:2bef98a2f59e...`, `local/nvbandwidth:cuda13.0.0` =
      `sha256:fec213b5a3bf...`, `ollama/ollama:0.32.14` =
      `sha256:9d30908e4114...`, `nvidia/cuda:13.0.0-base-ubuntu24.04` =
      `sha256:6e43a6b02e5f...`.

## B. New board, before the first boot

- [x] (2026-11-22: BIOS 4101 already supports the CPU, no flash needed)
      **BIOS for the i7-14700** (14th gen): flash a Z690 Formula BIOS that lists
      the CPU as supported, with BIOS FlashBack (works without a CPU).
- [x] (2026-11-22: ports 00:01.0 and 00:01.1, both Gen5 x8)
      **GPUs in the two CPU-connected x16 slots** (x8/x8). Check the manual's
      lane-sharing table: some M.2 slots take lanes from the PCIe slots; do
      not put the NVMe in one of those.
- [x] (2026-11-22: disabled, driver loads) **Secure Boot off.** The NVIDIA module is signed with a local MOK that
      is enrolled in the old board's NVRAM. With Secure Boot on, `nvidia.ko`
      will not load. (Alternative: keep it on and re-enroll the MOK with
      `mokutil --import`.)
- [x] (2026-11-22: RAM 6000 MT/s, ReBAR on, images identical; power limits
      = Intel defaults by decision) **Same platform settings as before** (`before/20-platform.txt`):
      - RAM: 2x 32 GB Corsair CMH64GX5M2D6000Z40, XMP on, **6000 MT/s**
        (JEDEC 4800). Two modules: use the slots the manual recommends
        (usually A2/B2).
      - CPU power limits **PL1 = PL2 = 241 W** (not Intel's default for
        the 14700). 2026-11-22: user decided to stay on the new BIOS's
        Intel defaults (65/219/341 W); CPU package power is sampled with
        `sudo scripts/cpu-power.sh after/NN-cpu-power.csv` in a second
        terminal during steps 10 and 14-17 to show PL1 never engages.
      - **Resizable BAR on** (before: BAR1 16384 MiB on both GPUs).
      - Microcode before: 0x133 (the new BIOS may bring another; the OS
        package can load a newer one; record it, do not chase it). Host-side bandwidth depends on these; a
      different RAM speed would mix a RAM effect into the board comparison.
- [x] (2026-11-22: booted normally) Boot entries live in the old board's NVRAM. The disk has the EFI
      fallback (`BOOTX64.EFI`, `fbx64.efi`), which recreates them; otherwise
      pick the NVMe's UEFI entry once.

## C. First boot checks (read-only, one at a time)

- [x] (2026-11-22, via driver/Ollama; nvidia-smi in step 1) `nvidia-smi` shows both GPUs (if not: Secure Boot, see B).
- [x] (2026-11-22: `wifi0` up; `enp5s0` now Marvell AQtion, down) **Network.** Before: Wi-Fi `wlp0s20f3` (the only interface in netplan)
      and Realtek `enp5s0` (r8169). The new board has different Ethernet
      chips, so `enp5s0` is gone and the new port gets a new name; Wi-Fi keeps
      its name only if it sits at the same PCI address. Check
      `ip -br link` and netplan.
- [x] (2026-11-22: disabled, config outdated; BIOS fan curves) **fancontrol.** Its config points at the old board's sensor chip
      (`nct6775.672`, `nct6798`) and fan headers. Expect it to fail or drive
      the wrong fans: `systemctl status fancontrol`, then `pwmconfig`.
- [x] (2026-11-22: ran without errors) **liquidctl-kraken.service** addresses NZXT devices by serial. The
      "NZXT Motherboard" USB device (1e71:201d) belongs to the N7 board and
      will be gone; check whether one of the two RGB controllers it addresses
      was on the board too: `systemctl status liquidctl-kraken`.
- [x] (2026-11-22: Ollama, Docker up, no model loaded) Services: `ollama`, `docker`, SearXNG up; `ollama ps` empty.

## D. Re-run, in this order (same commands, output to `after/`)

Done 2026-11-22, bundled at the user's request: `scripts/after-part1.sh`
(steps 1-4, 8) and `scripts/after-part2.sh` (steps 10, 11, 14-17 with CPU
power sampling). All results in the journal and `results/summary.md`.

Expected values after the swap are in section E. Steps 5-7, 9, 13 are
installs or script writing and are not repeated.

1. **Versions** -> `after/01-versions.txt`; compare with `before/01-*`, plus
   the platform check (step 20a with `after/20-platform.txt`).

```bash
cd ~/benchmarks/2026-11-boardswap
Q=index,name,pci.bus_id,driver_version
Q=$Q,vbios_version,power.limit,persistence_mode
{
  date -u
  uname -r
  nvidia-smi --query-gpu=$Q --format=csv
  ollama --version
  docker --version
  dpkg -l | grep -E 'nvidia-container|libnvidia-container'
} 2>&1 | tee after/01-versions.txt
```

2. **PCIe links**. The bus addresses may change, so the GPUs and their ports
   are looked up instead of hard-coded:

```bash
cd ~/benchmarks/2026-11-boardswap
{
  date -u
  for g in $(lspci -D -d 10de: | awk '/VGA/ {print $1}'); do
    p=$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$g)")")
    for d in "$p" "$g"; do
      lspci -s "$d"
      sudo lspci -vv -s "$d" | grep -E 'LnkCap:|LnkSta:'
    done
  done
} 2>&1 | tee after/02-pcie-links.txt
```

3. **Topology**:

```bash
cd ~/benchmarks/2026-11-boardswap
{
  date -u
  nvidia-smi topo -m
  echo
  nvidia-smi topo -p2p r
} 2>&1 | tee after/03-topology.txt
```

4. **Idle power** (60 s), then the summary:

```bash
cd ~/benchmarks/2026-11-boardswap
Q=timestamp,index,pstate,power.draw,temperature.gpu
Q=$Q,fan.speed,memory.used,clocks.gr,clocks.mem
Q=$Q,pcie.link.gen.current,pcie.link.width.current
{
  date -u
  ollama ps
  timeout 60 nvidia-smi --query-gpu=$Q --format=csv -l 1
} 2>&1 | tee after/04-idle-power.txt
scripts/idle-summary.py after/04-idle-power.txt |
  tee after/04-idle-power-summary.txt
```

8. **Docker GPU smoke test**; the digest must be `sha256:6e43a6b02e5f...`:

```bash
cd ~/benchmarks/2026-11-boardswap
I=nvidia/cuda:13.0.0-base-ubuntu24.04
Q=index,name,pci.bus_id,driver_version
{
  sudo docker run --rm --gpus all "$I" nvidia-smi
  sudo docker run --rm --gpus all "$I" nvidia-smi --query-gpu=$Q --format=csv
  sudo docker image inspect "$I" --format '{{index .RepoDigests 0}}'
} 2>&1 | tee after/08-docker-gpu-smoke.txt
```

10. **nvbandwidth** (nothing else running), then the CSV:

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/nvbandwidth:cuda13.0.0
{
  date -u
  ollama ps
  sudo docker run --rm --gpus all "$T"
} 2>&1 | tee after/10-nvbandwidth.txt
scripts/nvbw-to-csv.py after/10-nvbandwidth.txt > results/nvbandwidth-after.csv
```

11. **Link under load**, then the summary:

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/nvbandwidth:cuda13.0.0
Q=timestamp,index,pstate,pcie.link.gen.current,pcie.link.width.current
Q=$Q,pcie.link.gen.max,pcie.link.width.max,power.draw,clocks.mem
{
  nvidia-smi --query-gpu=$Q --format=csv -lms 200 > after/11-link-samples.csv &
  sudo docker run --rm --gpus all "$T" -t host_to_all_memcpy_ce -i 10
  kill $!
} 2>&1 | tee after/11-link-under-load.txt
scripts/link-summary.py after/11-link-samples.csv | tee after/11-link-summary.txt
```

12. **Images unchanged** (no pull): `after/20-platform.txt` from step 20a
    lists the IDs; they must equal `before/20-platform.txt`.
14. `scripts/bench-llamacpp.sh after single`
15. `scripts/bench-llamacpp.sh after dual`
16. `scripts/bench-ollama.sh after`
17. `scripts/bench-llamaserver.sh after`

Then the tables:

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/make-tps-table.py after
scripts/make-summary.py
```

and the "After the swap" part of `results/summary-findings.md` (Claude).

## E. Expectations to check against

- Links under load: both GPUs Gen5 x8.
- nvbandwidth GPU1: close to GPU0's 17-20 GB/s (before 7.2), latency close to
  GPU0's ~610 ns (before 1191).
- Both GPUs at once: GPU1 no longer drops 19-27 %, if the chipset path was
  the cause.
- P2P: probably still `CNS` (also an Intel desktop platform).
- One card and layer split: unchanged within ~1 % (control).
- Tensor split and tensor + MTP: the only configurations where a gain in t/s
  is expected; before they reached 69-83 % of the ideal 2x.
