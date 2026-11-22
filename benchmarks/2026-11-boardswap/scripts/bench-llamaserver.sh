#!/usr/bin/env bash
# llama.cpp llama-server matrix (step 17), measured exactly like Ollama in
# step 16: same client prompt and request pattern, and the same server options
# Ollama passes to its bundled llama-server (-c 4096 -np 1 -fa on -b 512
# -ub 512). Gives load times and t/s that compare 1:1 with Ollama.
#   single-card models: gpu0, gpu1, layer, tensor
#   dual models:        layer, tensor
#   models in MTP_MODELS additionally: layer-mtp, tensor-mtp (speculative
#   decoding with the model's MTP head, same flags Ollama uses)
# Load time = wall time from `docker run` until /health is ok (includes the
# container start, ~1 s; Ollama's load_duration does not).
#
# Usage (z790, normal user; calls sudo docker):
#   scripts/bench-llamaserver.sh before
# Output: <phase>/17-llamaserver.jsonl, <phase>/17-llamaserver.log,
#         <phase>/17-llamaserver-gpu.csv, <phase>/17-llamaserver/<model>__<config>.log
set -euo pipefail

PHASE=${1:?usage: $0 before|after}
cd "$(dirname "$0")/.."

IMG=local/llama.cpp:b12464-nccl
IMG_ID=sha256:2bef98a2f59e6920b1f00ceb17c443ee02851cc7ff53c164ce10dc4d6b9a0c1b
BLOBS=/usr/share/ollama/.ollama/models/blobs
PORT=11436
URL=http://127.0.0.1:$PORT
NAME=bench-llamaserver
SERVER=(-ngl 99 -c 4096 -np 1 -fa on -b 512 -ub 512 --host 0.0.0.0 --port 8080)
MTP=(--spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-backend-sampling)
MTP_MODELS=" qwen3.8-27b "

OUT=$PHASE/17-llamaserver
LOG=$OUT.log
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1

if [ "$(sudo docker image inspect "$IMG" --format '{{.Id}}')" != "$IMG_ID" ]; then
  echo "ABORT: $IMG is not image $IMG_ID"; exit 1
fi
if ollama ps | tail -n +2 | grep -q .; then
  echo "ABORT: the Ollama service has a model loaded (ollama ps)"; exit 1
fi

Q=timestamp,index,pstate,power.draw,temperature.gpu,memory.used
Q=$Q,clocks.gr,clocks.mem,pcie.link.gen.current,pcie.link.width.current
nvidia-smi --query-gpu=$Q --format=csv -lms 500 > "$OUT-gpu.csv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null; sudo docker rm -f $NAME >/dev/null 2>&1' EXIT

echo "== $(date -u)  phase=$PHASE image=$IMG ($IMG_ID)"
echo "== llama-server ${SERVER[*]}"
sudo docker run --rm --entrypoint /app/llama-server "$IMG" --version 2>&1 | tail -2
echo "== speculative options in this build:"
sudo docker run --rm --entrypoint /app/llama-server "$IMG" --help 2>&1 |
  grep -E -- '--spec-type|--spec-draft-n-max|--spec-draft-backend' || echo "  none found"

grep -v '^#' scripts/models.tsv |
while IFS=$'\t' read -r key tag blob fit engines; do
  [ "$engines" = both ] || continue
  if [ "$fit" = single ]; then cfgs=(gpu0 gpu1 layer tensor); else cfgs=(layer tensor); fi
  case $MTP_MODELS in *" $key "*) cfgs+=(layer-mtp tensor-mtp) ;; esac
  for cfg in "${cfgs[@]}"; do
    case $cfg in
      gpu0)   gpus=device=0; opts=() ;;
      gpu1)   gpus=device=1; opts=() ;;
      layer)  gpus=all;      opts=(-sm layer) ;;
      tensor) gpus=all;      opts=(-sm tensor) ;;
      layer-mtp)  gpus=all;  opts=(-sm layer "${MTP[@]}") ;;
      tensor-mtp) gpus=all;  opts=(-sm tensor "${MTP[@]}") ;;
    esac
    echo
    echo "== $(date -u +%T)  $key ($tag)  config=$cfg"
    t0=$(date +%s.%N)
    sudo docker run -d --name $NAME --gpus "$gpus" --shm-size=1g \
      -v "$BLOBS":/models:ro -p 127.0.0.1:$PORT:8080 \
      --entrypoint /app/llama-server "$IMG" \
      -m "/models/$blob" "${SERVER[@]}" "${opts[@]}" > /dev/null < /dev/null
    ready=0
    for _ in $(seq 600); do
      if curl -fs "$URL/health" > /dev/null 2>&1; then ready=1; break; fi
      [ "$(sudo docker inspect -f '{{.State.Running}}' $NAME)" = true ] || break
      sleep 0.5
    done
    load_s=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN { print a - b }')
    if [ $ready = 1 ]; then
      python3 scripts/llamaserver-client.py "$URL" "$key" "$cfg" \
        "$OUT.jsonl" 5 "$load_s" < /dev/null \
        || echo "!! FAILED: $key $cfg (client exit $?)"
    else
      echo "!! FAILED: $key $cfg (server not ready, see $OUT/${key}__$cfg.log)"
    fi
    sudo docker logs $NAME 2>&1 |
      sed -E 's/GPU-[0-9a-fA-F-]{36}/GPU-<redacted>/g' \
      > "$OUT/${key}__$cfg.log"
    sudo docker rm -f $NAME > /dev/null
    sleep 5
  done
done

echo
echo "== done $(date -u)"
