#!/usr/bin/env python3
"""Summarize an idle sampling file from step 4 (nvidia-smi --query-gpu CSV).

Usage: scripts/idle-summary.py before/04-idle-power.txt
Prints per GPU: sample count, power avg/min/max, temperature range, max memory
used, and the distinct pstate / fan / clock / link values seen.
"""
import csv
import sys
from collections import defaultdict

rows = defaultdict(list)
with open(sys.argv[1]) as f:
    lines = [l for l in f if l[:4].isdigit() and "/" in l[:8]]
for r in csv.reader(lines, skipinitialspace=True):
    rows[r[1]].append(r)

num = lambda s: float(s.split()[0])
distinct = lambda rs, i: ",".join(sorted({r[i] for r in rs}))

print(f'{"gpu":3} {"n":>3} {"W avg":>6} {"W min":>6} {"W max":>6} '
      f'{"degC":>6} {"MiB":>4}  pstate fan  gr/mem MHz  link')
for gpu, rs in sorted(rows.items()):
    w = [num(r[3]) for r in rs]
    t = [int(r[4]) for r in rs]
    mem = max(num(r[6]) for r in rs)
    print(f'{gpu:3} {len(rs):3} {sum(w) / len(w):6.2f} {min(w):6.2f} '
          f'{max(w):6.2f} {min(t):>3}-{max(t):<2} {mem:4.0f}  '
          f'{distinct(rs, 2):6} {distinct(rs, 5):4} '
          f'{distinct(rs, 7).replace(" MHz", "")}/'
          f'{distinct(rs, 8).replace(" MHz", "")}     '
          f'Gen{distinct(rs, 9)} x{distinct(rs, 10)}')
