#!/usr/bin/env python3
"""Summarize the step 11 link samples (nvidia-smi CSV, 200 ms interval).

Usage: scripts/link-summary.py before/11-link-samples.csv
Per GPU: count of each (pstate, link, max link, memory clock) state, plus the
time span and power of the samples under load (link gen above 1).
"""
import csv
import sys
from collections import Counter, defaultdict

rows = list(csv.reader(open(sys.argv[1]), skipinitialspace=True))[1:]
states = defaultdict(Counter)
load = defaultdict(list)
for ts, gpu, pstate, gen, width, gmax, wmax, power, mem in rows:
    states[gpu][(pstate, f"Gen{gen} x{width}", f"max Gen{gmax} x{wmax}", mem)] += 1
    if gen != "1":
        load[gpu].append((ts, float(power.split()[0])))

for gpu in sorted(states):
    print(f"GPU{gpu}:")
    for (pstate, link, lmax, mem), n in states[gpu].most_common():
        print(f"  {n:4} samples  {pstate}  {link}  ({lmax})  mem {mem}")
    if s := load[gpu]:
        w = [p for _, p in s]
        print(f"  under load: {len(s)} samples, {s[0][0][11:]} .. {s[-1][0][11:]}, "
              f"power avg {sum(w) / len(w):.1f} W, max {max(w):.1f} W")
