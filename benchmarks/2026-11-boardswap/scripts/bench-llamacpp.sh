#!/usr/bin/env bash
# llama-bench matrix (steps 14 and 15). Every model in scripts/models.tsv with
# engines=both runs in every configuration it fits:
#   single-card models: gpu0, gpu1, layer (both cards), tensor (both cards)
#   dual models:        layer, tensor
# Each run: pp512 and tg128, 5 repetitions, all layers on GPU, flash attention.
#
# Image: the pinned llama.cpp build 12464 with NCCL 2.32.6 (journal 14e,
# scripts/llamacpp-nccl/Dockerfile), checked by image ID. `-sm row` is not used:
# this build fails with "does not support split buffers" (journal 14/14b).
# `-sm tensor` syncs the cards with NCCL through /dev/shm, hence --shm-size.
#
# Usage (z790, normal user; calls sudo docker):
#   scripts/bench-llamacpp.sh before single    # step 14
#   scripts/bench-llamacpp.sh before dual      # step 15
# Output: <phase>/NN-llamabench/<model>__<config>.jsonl (one file per run),
#         <phase>/NN-llamabench.log, <phase>/NN-llamabench-gpu.csv (500 ms samples)
set -euo pipefail

PHASE=${1:?usage: $0 before|after single|dual}
GROUP=${2:?usage: $0 before|after single|dual}
cd "$(dirname "$0")/.."

case $GROUP in
  single) NN=14; CONFIGS=(gpu0 gpu1 layer tensor) ;;
  dual)   NN=15; CONFIGS=(layer tensor) ;;
  *)      echo "group must be single or dual" >&2; exit 2 ;;
esac

IMG=local/llama.cpp:b12464-nccl
IMG_ID=sha256:2bef98a2f59e6920b1f00ceb17c443ee02851cc7ff53c164ce10dc4d6b9a0c1b
BLOBS=/usr/share/ollama/.ollama/models/blobs
BENCH=(-ngl 99 -fa on -p 512 -n 128 -r 5 -o jsonl -oe md)

OUT=$PHASE/$NN-llamabench
LOG=$OUT.log
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1

if [ "$(sudo docker image inspect "$IMG" --format '{{.Id}}')" != "$IMG_ID" ]; then
  echo "ABORT: $IMG is not image $IMG_ID"; exit 1
fi

# The Ollama service must not hold a model: it would occupy VRAM.
if ollama ps | tail -n +2 | grep -q .; then
  echo "ABORT: the Ollama service has a model loaded (ollama ps)"; exit 1
fi

Q=timestamp,index,pstate,power.draw,temperature.gpu,memory.used
Q=$Q,clocks.gr,clocks.mem,pcie.link.gen.current,pcie.link.width.current
nvidia-smi --query-gpu=$Q --format=csv -lms 500 > "$OUT-gpu.csv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

echo "== $(date -u)  phase=$PHASE group=$GROUP image=$IMG ($IMG_ID)"
echo "== llama-bench ${BENCH[*]}"

grep -v '^#' scripts/models.tsv |
while IFS=$'\t' read -r key tag blob fit engines; do
  [ "$fit" = "$GROUP" ] && [ "$engines" = both ] || continue
  for cfg in "${CONFIGS[@]}"; do
    case $cfg in
      gpu0)   gpus=device=0; sm=() ;;
      gpu1)   gpus=device=1; sm=() ;;
      layer)  gpus=all;      sm=(-sm layer) ;;
      tensor) gpus=all;      sm=(-sm tensor) ;;
    esac
    echo
    echo "== $(date -u +%T)  $key ($tag)  config=$cfg"
    sudo docker run --rm --gpus "$gpus" --shm-size=1g \
      -v "$BLOBS":/models:ro --entrypoint /app/llama-bench "$IMG" \
      -m "/models/$blob" "${BENCH[@]}" "${sm[@]}" \
      > "$OUT/${key}__$cfg.jsonl" < /dev/null \
      || echo "!! FAILED: $key $cfg (exit $?)"
    sleep 5
  done
done

echo
echo "== done $(date -u)"
