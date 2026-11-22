#!/usr/bin/env python3
"""Summarize llama-bench JSONL files (steps 14/15) into a table and a CSV.

Usage: scripts/llamabench-summary.py OUT.csv DIR [DIR ...]
       e.g. scripts/llamabench-summary.py results/llamabench-before.csv \
              before/14-llamabench before/15-llamabench
Files are named <model>__<config>.jsonl. Empty files (failed runs) are listed
as FAILED. CSV columns: model,config,test,tps,stddev,model_type,split_mode,
build,n_reps.
"""
import csv
import json
import pathlib
import sys

KNOWN = ["gpu0", "gpu1", "layer", "tensor", "row"]
out, dirs = sys.argv[1], sys.argv[2:]
rows, failed = [], []
for d in dirs:
    for f in sorted(pathlib.Path(d).glob("*.jsonl")):
        model, config = f.stem.split("__")
        recs = [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
        if not recs:
            failed.append((model, config))
        for r in recs:
            test = f"pp{r['n_prompt']}" if r["n_prompt"] else f"tg{r['n_gen']}"
            rows.append({
                "model": model, "config": config, "test": test,
                "tps": round(r["avg_ts"], 2), "stddev": round(r["stddev_ts"], 2),
                "model_type": r["model_type"], "split_mode": r["split_mode"],
                "build": r["build_number"], "n_reps": len(r["samples_ts"]),
            })

with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=rows[0].keys())
    w.writeheader()
    w.writerows(rows)

ORDER = [c for c in KNOWN
         if any(r["config"] == c for r in rows) or any(x == c for _, x in failed)]
models = list(dict.fromkeys(r["model"] for r in rows) | dict.fromkeys(m for m, _ in failed))
for test in ("pp512", "tg128"):
    print(f"\n{test} (t/s, mean of 5)")
    print(f"{'model':16}" + "".join(f"{c:>10}" for c in ORDER))
    for m in models:
        cells = []
        for c in ORDER:
            v = [r["tps"] for r in rows if (r["model"], r["config"], r["test"]) == (m, c, test)]
            cells.append(f"{v[0]:10.1f}" if v else
                         f"{'FAILED':>10}" if (m, c) in failed else f"{'-':>10}")
        print(f"{m:16}" + "".join(cells))
