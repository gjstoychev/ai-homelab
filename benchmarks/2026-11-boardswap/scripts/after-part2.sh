#!/usr/bin/env bash
# After the swap, part 2: steps 10, 11, 14, 15, 16 and 17 in one go, with the
# same commands and scripts as before the swap, while the CPU package power is
# sampled the whole time (scripts/cpu-power.sh -> after/cpu-power.csv; the new
# BIOS uses Intel's default limits, see journal B4). Step start times go to
# after/part2-steps.log, so the power samples can be matched to the steps.
# Bundled at the user's request (2026-11-22). Takes about an hour.
#
# Usage (z790, normal user; asks for the sudo password once):
#   scripts/after-part2.sh
set -uo pipefail
cd "$(dirname "$0")/.."
sudo -v

step() { echo "== $(date -u +%T) step $*" | tee -a after/part2-steps.log; }

sudo scripts/cpu-power.sh after/cpu-power.csv &
CPID=$!
trap 'sudo kill $CPID 2>/dev/null' EXIT
step "start (CPU power sampling, pid $CPID)"

step "10 nvbandwidth"
T=local/nvbandwidth:cuda13.0.0
{
  date -u
  ollama ps
  sudo docker run --rm --gpus all "$T"
} 2>&1 | tee after/10-nvbandwidth.txt

step "11 link under load"
Q=timestamp,index,pstate,pcie.link.gen.current,pcie.link.width.current
Q=$Q,pcie.link.gen.max,pcie.link.width.max,power.draw,clocks.mem
{
  nvidia-smi --query-gpu=$Q --format=csv -lms 200 > after/11-link-samples.csv &
  sudo docker run --rm --gpus all "$T" -t host_to_all_memcpy_ce -i 10
  kill $!
} 2>&1 | tee after/11-link-under-load.txt

step "14 llama-bench single"
scripts/bench-llamacpp.sh after single

step "15 llama-bench dual"
scripts/bench-llamacpp.sh after dual

step "16 Ollama"
scripts/bench-ollama.sh after

step "17 llama-server"
scripts/bench-llamaserver.sh after

step "done"
