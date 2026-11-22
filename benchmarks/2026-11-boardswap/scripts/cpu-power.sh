#!/usr/bin/env bash
# CPU package power, sampled once per second from the RAPL energy counter
# (root-only), until Ctrl+C. Runs in a second terminal next to a benchmark;
# the benchmark scripts stay unchanged. Added after the swap: the new BIOS
# uses Intel's default limits (PL1 65 W, PL2 219 W) instead of 241/241 W, and
# this shows whether the CPU ever gets near PL1 during the GPU benchmarks.
#
# Usage (z790): sudo scripts/cpu-power.sh after/NN-cpu-power.csv
# Output CSV: utc_time,package_w (plus the limits in a comment line)
set -euo pipefail

OUT=${1:?usage: sudo $0 OUTPUT.csv}
R=/sys/class/powercap/intel-rapl:0
MAX=$(cat $R/max_energy_range_uj)

{
  echo "# PL1 $(($(cat $R/constraint_0_power_limit_uw) / 1000000)) W," \
       "PL2 $(($(cat $R/constraint_1_power_limit_uw) / 1000000)) W"
  echo "utc_time,package_w"
} > "$OUT"

prev_e=$(cat $R/energy_uj)
prev_t=$(date +%s.%N)
while sleep 1; do
  e=$(cat $R/energy_uj)
  t=$(date +%s.%N)
  awk -v e="$e" -v pe="$prev_e" -v t="$t" -v pt="$prev_t" -v max="$MAX" \
    'BEGIN { d = e - pe; if (d < 0) d += max;
             printf "%s,%.1f\n", strftime("%H:%M:%S", t, 1), d / (t - pt) / 1e6 }' \
    >> "$OUT"
  prev_e=$e
  prev_t=$t
done
