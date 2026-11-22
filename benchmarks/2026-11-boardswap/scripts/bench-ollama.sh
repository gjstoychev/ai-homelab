#!/usr/bin/env bash
# Ollama matrix in Docker (step 16). Every model in scripts/models.tsv:
#   single-card models: gpu0, gpu1, spread (both cards, OLLAMA_SCHED_SPREAD=1)
#   dual models:        spread
# For every run a fresh container starts, so request 0 measures a load from
# disk cache into VRAM. Then 5 measured requests (scripts/ollama-client.py).
# Models are mounted read-only; the host's Ollama service is not touched.
#
# Usage (z790, normal user; calls sudo docker):
#   scripts/bench-ollama.sh before
# Output: <phase>/16-ollama.jsonl, <phase>/16-ollama.log,
#         <phase>/16-ollama-gpu.csv (500 ms samples),
#         <phase>/16-ollama/<model>__<config>.log (server logs, GPU UUIDs
#         redacted)
set -euo pipefail

PHASE=${1:?usage: $0 before|after}
cd "$(dirname "$0")/.."

IMG=ollama/ollama:0.32.14
MODELS=/usr/share/ollama/.ollama/models
PORT=11435
URL=http://127.0.0.1:$PORT
NAME=bench-ollama

OUT=$PHASE/16-ollama
LOG=$OUT.log
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1

if ollama ps | tail -n +2 | grep -q .; then
  echo "ABORT: the Ollama service has a model loaded (ollama ps)"; exit 1
fi

Q=timestamp,index,pstate,power.draw,temperature.gpu,memory.used
Q=$Q,clocks.gr,clocks.mem,pcie.link.gen.current,pcie.link.width.current
nvidia-smi --query-gpu=$Q --format=csv -lms 500 > "$OUT-gpu.csv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null; sudo docker rm -f $NAME >/dev/null 2>&1' EXIT

echo "== $(date -u)  phase=$PHASE image=$IMG"
sudo docker image inspect "$IMG" --format '== digest {{index .RepoDigests 0}}'

grep -v '^#' scripts/models.tsv | while IFS=$'\t' read -r key tag blob fit engines; do
  if [ "$fit" = single ]; then cfgs=(gpu0 gpu1 spread); else cfgs=(spread); fi
  for cfg in "${cfgs[@]}"; do
    case $cfg in
      gpu0)   gpus=device=0; spread=0 ;;
      gpu1)   gpus=device=1; spread=0 ;;
      spread) gpus=all;      spread=1 ;;
    esac
    echo
    echo "== $(date -u +%T)  $key ($tag)  config=$cfg"
    sudo docker run -d --name $NAME --gpus "$gpus" \
      -e OLLAMA_SCHED_SPREAD=$spread -e OLLAMA_FLASH_ATTENTION=1 \
      -e OLLAMA_NOPRUNE=1 -e OLLAMA_KEEP_ALIVE=10m \
      -v "$MODELS":/root/.ollama/models:ro \
      -p 127.0.0.1:$PORT:11434 "$IMG" > /dev/null < /dev/null
    for _ in $(seq 60); do
      curl -fs "$URL/api/version" > /dev/null && break
      sleep 1
    done
    python3 scripts/ollama-client.py "$URL" "$tag" "$key" "$cfg" \
      "$OUT.jsonl" 5 < /dev/null \
      || echo "!! FAILED: $key $cfg (exit $?)"
    sudo docker logs $NAME 2>&1 |
      sed -E 's/GPU-[0-9a-fA-F-]{36}/GPU-<redacted>/g' \
      > "$OUT/${key}__$cfg.log"
    sudo docker rm -f $NAME > /dev/null
    sleep 5
  done
done

echo
echo "== done $(date -u)"
