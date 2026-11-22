#!/usr/bin/env python3
"""Turn nvbandwidth text output (step 10) into CSV: testcase,unit,gpu0,gpu1,sum,cv.

Usage: scripts/nvbw-to-csv.py before/10-nvbandwidth.txt > results/nvbandwidth-before.csv
Waived testcases are skipped. Values are copied as printed (GB/s, latency in ns).
"""
import re
import sys

print("testcase,unit,gpu0,gpu1,sum,cv")
test = unit = None
values = []
for line in open(sys.argv[1]):
    if m := re.match(r"Running (\S+)\.", line):
        test, unit, values = m.group(1), None, []
    elif test and "(GB/s)" in line:
        unit = "GB/s"
    elif test and "(ns)" in line:
        unit = "ns"
    elif test and re.match(r"\s*0\s+[\d.]+\s+[\d.]+\s*$", line):
        values = line.split()[1:]
    elif m := re.match(r"SUM (\S+) ([\d.]+)", line):
        total = m.group(2)
    elif m := re.match(r"COEFFICIENT_OF_VARIATION (\S+) ([\d.]+)", line):
        print(f"{test},{unit},{values[0]},{values[1]},{total},{m.group(2)}")
        test = None
