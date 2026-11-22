#!/usr/bin/env python3
"""Tokens per second for every model, scenario and engine in one place.

Usage: scripts/make-tps-table.py PHASE
  reads  PHASE/14-llamabench/*.jsonl, PHASE/15-llamabench/*.jsonl (llama-bench)
         PHASE/17-llamaserver.jsonl (scripts/llamaserver-client.py)
         PHASE/16-ollama.jsonl (scripts/ollama-client.py)
  writes results/tps-PHASE.csv (long format, one row per engine/model/scenario/test)
         results/tps-PHASE.md  (side-by-side table, load times, one table per metric)
Missing inputs are skipped, so the tables can be built while runs are pending.

Engines: llama-bench (llama.cpp's benchmark tool, synthetic pp512/tg128),
llama-server (llama.cpp's server, measured with the same client and prompt as
Ollama), Ollama. Scenarios: gpu0 / gpu1 = one card; layer = both cards, layer
split (Ollama: OLLAMA_SCHED_SPREAD=1); tensor = both cards, tensor split
(llama.cpp only); "-mtp" = with MTP speculative decoding. An Ollama run whose
server log shows `--spec-type` is filed under the -mtp scenario, because that
is what it ran.
"""
import csv
import json
import pathlib
import statistics
import sys

phase = sys.argv[1]
root = pathlib.Path(__file__).resolve().parent.parent
models = [l.split("\t") for l in (root / "scripts/models.tsv").read_text().splitlines()
          if l and not l.startswith("#")]
NAMES = {
    "gemma3-4b": "TranslateGemma 4B", "llama3-8b": "Llama 3 8B (Q4_0)",
    "llama3.1-8b": "Llama 3.1 8B", "qwen3-8b": "Qwen3 8B",
    "qwen2.5-14b": "Qwen2.5 14B", "qwen3-14b": "Qwen3 14B",
    "qwen3.8-27b": "Qwen3.8 27B", "qwen3-30b-a3b": "Qwen3 30B-A3B (MoE)",
    "qwen3-32b": "Qwen3 32B",
}
SCEN = {"gpu0": "1 card, GPU0", "gpu1": "1 card, GPU1",
        "layer": "2 cards, layer split", "tensor": "2 cards, tensor split",
        "layer-mtp": "2 cards, layer split + MTP",
        "tensor-mtp": "2 cards, tensor split + MTP"}
ENGINES = ["llama-bench", "llama-server", "Ollama"]
rows = []

# Weight quantization per model, from the inventory (Ollama tag -> quant).
INV = root / "before/05-model-inventory.txt"
TAG_QUANT = {l.split()[0]: l.split()[-1] for l in INV.read_text().splitlines()
             if l and l[0].isalpha() and not l.startswith("tag")}
QUANT = {key: TAG_QUANT.get(tag, "") for key, tag, *_ in models}


def ollama_kv(key, cfg):
    """K/V cache types from an Ollama run's server log ("K (f16): ..., V (f16)")."""
    log = root / phase / "16-ollama" / f"{key}__{cfg}.log"
    if not log.exists():
        return ""
    import re
    kv = sorted(set(re.findall(r"K \(([a-z0-9_]+)\).*?V \(([a-z0-9_]+)\)",
                               log.read_text(errors="replace"))))
    return " ".join(f"{k}/{v}" for k, v in kv)

for nn in ("14", "15"):
    for f in sorted((root / phase / f"{nn}-llamabench").glob("*.jsonl")):
        key, scen = f.stem.split("__")
        for r in (json.loads(l) for l in f.read_text().splitlines() if l.strip()):
            test = "pp" if r["n_prompt"] else "tg"
            rows.append({
                "phase": phase, "engine": "llama-bench", "model": key,
                "scenario": scen, "test": test,
                "tokens": r["n_prompt"] or r["n_gen"],
                "tps": round(r["avg_ts"], 2), "stddev": round(r["stddev_ts"], 2),
                "n": len(r["samples_ts"]), "load_s": "", "draft_accept": "",
                "quant": QUANT.get(key, ""), "kv_cache": f"{r['type_k']}/{r['type_v']}",
            })


def client_rows(path, engine, scen_of, load_of, kv_of):
    if not path.exists():
        return
    recs = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    for key, cfg in dict.fromkeys((r["key"], r["config"]) for r in recs):
        sel = [r for r in recs if (r["key"], r["config"]) == (key, cfg)]
        meas = [r for r in sel if r["kind"] == "measured"]
        first = [r for r in sel if r["kind"] != "measured"]
        drafted = sum(r.get("draft_n") or 0 for r in meas)
        accept = (round(sum(r.get("draft_n_accepted") or 0 for r in meas) / drafted, 3)
                  if drafted else "")
        for test, fld, cnt in (("pp", "pp_tps", "prompt_eval_count"),
                               ("tg", "tg_tps", "eval_count")):
            v = [r[fld] for r in meas]
            if not v:
                continue
            rows.append({
                "phase": phase, "engine": engine, "model": key,
                "scenario": scen_of(key, cfg), "test": test,
                "tokens": round(statistics.mean(r[cnt] for r in meas)),
                "tps": round(statistics.mean(v), 2),
                "stddev": round(statistics.stdev(v), 2) if len(v) > 1 else 0,
                "n": len(v), "load_s": load_of(first[0]) if first else "",
                "draft_accept": accept,
                "quant": QUANT.get(key, ""), "kv_cache": kv_of(key, cfg),
            })


def ollama_scen(key, cfg):
    scen = "layer" if cfg == "spread" else cfg
    log = root / phase / "16-ollama" / f"{key}__{cfg}.log"
    if log.exists() and "--spec-type" in log.read_text(errors="replace"):
        scen += "-mtp"
    return scen


# llama-server's logs do not print the cache type at default verbosity; the
# script sets no -ctk/-ctv, so it is the build's default (f16, as llama-bench
# of the same build records).
client_rows(root / phase / "17-llamaserver.jsonl", "llama-server",
            lambda k, c: c, lambda r: r["load_s"], lambda k, c: "f16/f16 (default)")
client_rows(root / phase / "16-ollama.jsonl", "Ollama",
            ollama_scen, lambda r: round(r["load_duration"] / 1e9, 2), ollama_kv)

(root / "results").mkdir(exist_ok=True)
with open(root / f"results/tps-{phase}.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["phase", "engine", "model", "scenario", "test",
                                      "tokens", "tps", "stddev", "n", "load_s",
                                      "draft_accept", "quant", "kv_cache"])
    w.writeheader()
    w.writerows(rows)


def get(key, eng, scen, test, field="tps"):
    v = [r[field] for r in rows if (r["model"], r["engine"], r["scenario"], r["test"])
         == (key, eng, scen, test)]
    return v[0] if v and v[0] != "" else None


def fmt(x, d=1):
    return "-" if x is None else f"{x:.{d}f}"


present = [(k, s) for k, *_ in models for s in SCEN
           if any(r["model"] == k and r["scenario"] == s for r in rows)]
md = [f"# Tokens per second ({phase} the swap)", "",
      "Generated by `scripts/make-tps-table.py`. Mean of 5 measured requests or",
      "repetitions; standard deviations in `results/tps-%s.csv`." % phase,
      "`-` = not run or not possible.", "",
      "- **llama-bench**: llama.cpp's benchmark tool, synthetic 512-token prompt",
      "  (pp) and 128 generated tokens (tg).",
      "- **llama-server**: llama.cpp's server, measured with the same client,",
      "  ~540-token text prompt and server options as Ollama (1:1 comparable).",
      "- **Ollama**: 0.32.14, which runs a bundled llama-server itself. Its",
      "  two-card mode is layer split (`OLLAMA_SCHED_SPREAD=1`).",
      "- Tensor split exists only in llama.cpp. MTP = speculative decoding with",
      "  the model's own multi-token prediction head; speed depends on how many",
      "  drafted tokens are accepted (acceptance rate in the CSV).",
      "- Weights: GGUF quantization as listed (Q4_K_M; Llama 3 8B Q4_0). KV cache:",
      "  f16 for K and V in every run (llama-bench records it per run, Ollama",
      "  logs it per load, llama-server runs with the default). Context 4096",
      "  tokens for llama-server and Ollama; flash attention on everywhere.", "",
      "## Side by side", "",
      "| Model | Quant | Scenario | tg llama-bench | tg llama-server | tg Ollama "
      "| pp llama-bench | pp llama-server | pp Ollama |",
      "|---|---|---|---:|---:|---:|---:|---:|---:|"]
for key, s in present:
    md.append(f"| {NAMES.get(key, key)} | {QUANT.get(key, '')} | {SCEN[s]} | "
              + " | ".join(fmt(get(key, e, s, t)) for t in ("tg", "pp") for e in ENGINES)
              + " |")
md += ["", "## Load time (s)", "",
       "From page cache. llama-server: `docker run` until /health ok (includes",
       "~1 s container start). Ollama: its reported load_duration.", "",
       "| Model | Scenario | llama-server | Ollama |", "|---|---|---:|---:|"]
for key, s in present:
    a, b = get(key, "llama-server", s, "tg", "load_s"), get(key, "Ollama", s, "tg", "load_s")
    if a is not None or b is not None:
        md.append(f"| {NAMES.get(key, key)} | {SCEN[s]} | {fmt(a)} | {fmt(b)} |")
md.append("")
for test, title in (("tg", "Generation (tg), t/s"), ("pp", "Prompt processing (pp), t/s")):
    cols = [(e, s) for e in ENGINES for s in SCEN
            if any(r["engine"] == e and r["scenario"] == s for r in rows)]
    md += [f"## {title}", "",
           "| Model | " + " | ".join(f"{e}: {SCEN[s]}" for e, s in cols) + " |",
           "|---|" + "---:|" * len(cols)]
    for key, *_ in models:
        if any(r["model"] == key for r in rows):
            md.append(f"| {NAMES.get(key, key)} | "
                      + " | ".join(fmt(get(key, e, s, test)) for e, s in cols) + " |")
    md.append("")
(root / f"results/tps-{phase}.md").write_text("\n".join(md))
print("\n".join(md))
