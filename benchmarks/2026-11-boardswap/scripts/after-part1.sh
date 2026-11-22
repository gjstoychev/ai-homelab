#!/usr/bin/env bash
# After the swap, part 1: steps 1, 2, 3, 4 and 8 in one go, with the same
# commands as before the swap (journal steps 1-4, 8; AFTER-SWAP.md section D).
# Bundled at the user's request (2026-11-22): the sandbox cannot reach the
# GPUs, Docker or sudo, so the user runs this once and Claude does the rest.
# Step 2 looks the GPUs and their ports up instead of using fixed addresses.
#
# Usage (z790, normal user; asks for the sudo password once):
#   scripts/after-part1.sh
set -uo pipefail
cd "$(dirname "$0")/.."
sudo -v

echo "== step 1: versions"
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

echo "== step 2: PCIe links"
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

echo "== step 3: topology"
{
  date -u
  nvidia-smi topo -m
  echo
  nvidia-smi topo -p2p r
} 2>&1 | tee after/03-topology.txt

echo "== step 4: idle power (60 s)"
Q=timestamp,index,pstate,power.draw,temperature.gpu
Q=$Q,fan.speed,memory.used,clocks.gr,clocks.mem
Q=$Q,pcie.link.gen.current,pcie.link.width.current
{
  date -u
  ollama ps
  timeout 60 nvidia-smi --query-gpu=$Q --format=csv -l 1
} > after/04-idle-power.txt 2>&1
tail -2 after/04-idle-power.txt

echo "== step 8: Docker GPU smoke test"
I=nvidia/cuda:13.0.0-base-ubuntu24.04
Q=index,name,pci.bus_id,driver_version
{
  sudo docker run --rm --gpus all "$I" nvidia-smi
  sudo docker run --rm --gpus all "$I" nvidia-smi --query-gpu=$Q --format=csv
  sudo docker image inspect "$I" --format '{{index .RepoDigests 0}}'
} 2>&1 | tee after/08-docker-gpu-smoke.txt

echo "== part 1 done $(date -u)"
