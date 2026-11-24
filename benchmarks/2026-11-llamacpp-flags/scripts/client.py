#!/usr/bin/env python3
"""Measure one step on a running llama-server.

Usage: scripts/client.py URL MODEL STEP OUT.jsonl REPS LOAD_S

Request 0 is a warm-up, 1..REPS are measured. Every request: the same long
prompt (about 4000 tokens, so prompt processing runs several micro-batches and
step 4's -b/-ub can show), 256 generated tokens (ignore_eos, so always 256),
temperature 0, seed 42, through the native /completion endpoint (no chat
template) with cache_prompt=false, so the whole prompt is processed every
time. The prompt text comes from the board-swap benchmark's client.
Every field of the server's "timings" is kept, not only the t/s.
"""
import json
import sys
import urllib.request

url, model, step, out = sys.argv[1:5]
reps, load_s = int(sys.argv[5]), float(sys.argv[6])

PARAGRAPH = (
    "The lighthouse keeper wrote down the weather every morning: wind "
    "direction, the height of the swell, the colour of the sky over the "
    "eastern headland and the number of ships that passed before noon. "
    "Over forty years the notebooks filled three shelves, and nobody but "
    "the keeper had ever read them. "
)
TEXT = PARAGRAPH * 72 + "When the station was automated, the notebooks"
N_PREDICT = 256


def post(path, body):
    req = urllib.request.Request(
        url + path, json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.load(r)


with open(out, "a") as f:
    for i in range(reps + 1):
        r = post("/completion", {
            "prompt": f"Request {i}. {TEXT}", "n_predict": N_PREDICT,
            "temperature": 0, "seed": 42, "cache_prompt": False, "ignore_eos": True,
        })
        t = r["timings"]
        row = {
            "model": model, "step": step, "request": i,
            "kind": "warmup" if i == 0 else "measured",
            "load_s": round(load_s, 2) if i == 0 else None,
            "pp_tokens": t["prompt_n"], "pp_tps": round(t["prompt_n"] / t["prompt_ms"] * 1000, 2),
            "tg_tokens": t["predicted_n"], "tg_tps": round(t["predicted_n"] / t["predicted_ms"] * 1000, 2),
            "timings": t,
        }
        f.write(json.dumps(row) + "\n")
        print(f"  {row['kind']:8} req {i}: pp {row['pp_tokens']} tok {row['pp_tps']:8.1f} t/s"
              f" | tg {row['tg_tokens']} tok {row['tg_tps']:6.1f} t/s"
              + (f" | load {load_s:.1f} s" if i == 0 else ""), flush=True)
