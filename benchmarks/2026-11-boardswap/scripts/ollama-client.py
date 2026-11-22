#!/usr/bin/env python3
"""Measure one model on an Ollama server (step 16).

Usage: scripts/ollama-client.py URL TAG KEY CONFIG OUT.jsonl [REPS]

Request 0 loads the model (load_duration = load time). Requests 1..REPS are
measured. Every prompt starts with a different request number, so Ollama
cannot reuse the KV cache from the previous request and must process the whole
prompt each time. raw=true skips the chat template (no system prompt, no
thinking tags), so the prompt is exactly the text below for every model.
Generation is fixed at 128 tokens; the prompt is ~500 tokens (exact count
depends on the tokenizer and is recorded).
"""
import json
import sys
import urllib.request

url, tag, key, config, out = sys.argv[1:6]
reps = int(sys.argv[6]) if len(sys.argv) > 6 else 5

PARAGRAPH = (
    "The lighthouse keeper wrote down the weather every morning: wind "
    "direction, the height of the swell, the colour of the sky over the "
    "eastern headland and the number of ships that passed before noon. "
    "Over forty years the notebooks filled three shelves, and nobody but "
    "the keeper had ever read them. "
)
TEXT = PARAGRAPH * 9 + "When the station was automated, the notebooks"
OPTIONS = {"num_predict": 128, "num_ctx": 4096, "temperature": 0, "seed": 42}


def post(path, body):
    req = urllib.request.Request(
        url + path, json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)


def get(path):
    with urllib.request.urlopen(url + path, timeout=30) as r:
        return json.load(r)


with open(out, "a") as f:
    for i in range(reps + 1):
        r = post("/api/generate", {
            "model": tag, "prompt": f"Request {i}. {TEXT}", "raw": True,
            "stream": False, "options": OPTIONS, "keep_alive": "10m",
        })
        row = {
            "key": key, "tag": tag, "config": config, "request": i,
            "kind": "load" if i == 0 else "measured",
            **{k: r.get(k) for k in (
                "load_duration", "prompt_eval_count", "prompt_eval_duration",
                "eval_count", "eval_duration", "total_duration")},
        }
        if i == 0:
            ps = get("/api/ps")["models"]
            row["ps"] = [{k: m.get(k) for k in ("name", "size", "size_vram")}
                         for m in ps]
        pp = row["prompt_eval_count"] / row["prompt_eval_duration"] * 1e9
        tg = row["eval_count"] / row["eval_duration"] * 1e9
        row["pp_tps"], row["tg_tps"] = round(pp, 2), round(tg, 2)
        f.write(json.dumps(row) + "\n")
        print(f"  {row['kind']:8} req {i}: pp {row['prompt_eval_count']} tok "
              f"{pp:8.1f} t/s | tg {row['eval_count']} tok {tg:6.1f} t/s"
              + (f" | load {row['load_duration'] / 1e9:.2f} s" if i == 0 else ""),
              flush=True)
        if i == 0:
            for m in row["ps"]:
                print(f"  ps: {m['name']} size {m['size'] / 2**30:.1f} GiB, "
                      f"in VRAM {m['size_vram'] / 2**30:.1f} GiB", flush=True)
