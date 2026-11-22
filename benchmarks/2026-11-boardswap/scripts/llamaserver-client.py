#!/usr/bin/env python3
"""Measure one model on a llama.cpp llama-server (step 17), the same way
scripts/ollama-client.py measures Ollama.

Usage: scripts/llamaserver-client.py URL KEY CONFIG OUT.jsonl REPS LOAD_S

Same prompt text, same request numbering (request 0 = warm-up, 1..REPS
measured), same 128 generated tokens, temperature 0, seed 42. Uses the native
/completion endpoint: the prompt is sent as is (no chat template, like
Ollama's raw=true) and cache_prompt=false, so the whole prompt is processed
every time. LOAD_S is the wall time from `docker run` until /health was ok,
measured by scripts/bench-llamaserver.sh. With speculative decoding the
server also reports drafted and accepted tokens; they are recorded.
"""
import json
import sys
import urllib.request

url, key, config, out = sys.argv[1:5]
reps, load_s = int(sys.argv[5]), float(sys.argv[6])

# Identical to scripts/ollama-client.py.
PARAGRAPH = (
    "The lighthouse keeper wrote down the weather every morning: wind "
    "direction, the height of the swell, the colour of the sky over the "
    "eastern headland and the number of ships that passed before noon. "
    "Over forty years the notebooks filled three shelves, and nobody but "
    "the keeper had ever read them. "
)
TEXT = PARAGRAPH * 9 + "When the station was automated, the notebooks"


def post(path, body):
    req = urllib.request.Request(
        url + path, json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)


with open(out, "a") as f:
    for i in range(reps + 1):
        r = post("/completion", {
            "prompt": f"Request {i}. {TEXT}", "n_predict": 128,
            "temperature": 0, "seed": 42, "cache_prompt": False,
        })
        t = r["timings"]
        row = {
            "key": key, "config": config, "request": i,
            "kind": "warmup" if i == 0 else "measured",
            "load_s": round(load_s, 2) if i == 0 else None,
            "prompt_eval_count": t["prompt_n"], "prompt_ms": t["prompt_ms"],
            "eval_count": t["predicted_n"], "predicted_ms": t["predicted_ms"],
            "pp_tps": round(t["prompt_n"] / t["prompt_ms"] * 1000, 2),
            "tg_tps": round(t["predicted_n"] / t["predicted_ms"] * 1000, 2),
            "draft_n": t.get("draft_n"), "draft_n_accepted": t.get("draft_n_accepted"),
        }
        f.write(json.dumps(row) + "\n")
        draft = (f" | draft {row['draft_n_accepted']}/{row['draft_n']} accepted"
                 if row["draft_n"] else "")
        print(f"  {row['kind']:8} req {i}: pp {row['prompt_eval_count']} tok "
              f"{row['pp_tps']:8.1f} t/s | tg {row['eval_count']} tok "
              f"{row['tg_tps']:6.1f} t/s" + draft
              + (f" | load {load_s:.2f} s" if i == 0 else ""), flush=True)
