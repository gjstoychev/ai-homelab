#!/usr/bin/env bash
# Run one step of the series on one model and record everything for it.
#
#   scripts/run-step.sh MODEL STEP [REPS] -- [llama-server options of the step]
#   e.g. scripts/run-step.sh qwen3.8-flash-next 1-cmoe 5 -- -cmoe
#
# MODEL is a key from scripts/models.tsv. The options every run shares are fixed
# here (BASE); the step adds its own after `--`. Runs as the user; sudo is asked
# for once at the start (page cache drop, CPU power from RAPL).
#
# Per run, in runs/<MODEL>/<STEP>.*:
#   .cmd       the exact server command and versions
#   .log       the server log (-lv 4)
#   .gpu.csv   nvidia-smi every 0.5 s: power, memory, clocks, temperature
#   .ram.csv   every 1 s: MemAvailable, page cache, server RSS (with mmap the
#              model's CPU part is page cache and counts as "available"), MiB read
#              from the NVMe since the start
#   .cpu.csv   CPU package power every 1 s (RAPL)
# and one line per request in runs/<MODEL>/results.jsonl (scripts/client.py).
set -euo pipefail

MODEL=${1:?usage: $0 MODEL STEP [REPS] -- [server options]}
STEP=${2:?usage: $0 MODEL STEP [REPS] -- [server options]}
shift 2
REPS=5
if [ $# -gt 0 ] && [ "$1" != "--" ]; then REPS=$1; shift; fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi
STEP_OPTS=("$@")

cd "$(dirname "$0")/.."
BIN=$HOME/llama.cpp/v1.0.0/build/bin/llama-server
PORT=8080
URL=http://127.0.0.1:$PORT
BASE=(--host 127.0.0.1 --port $PORT -np 1 --cache-ram 0 -t 8 -c 8192 -lv 4)

shard=$(awk -F'\t' -v k="$MODEL" '$1 == k { print $2 }' scripts/models.tsv)
[ -n "$shard" ] || { echo "ABORT: $MODEL not in scripts/models.tsv"; exit 1; }
M=$HOME/models/$shard
OUT=runs/$MODEL
P=$OUT/$STEP
mkdir -p "$OUT"
[ ! -e "$P.log" ] || { echo "ABORT: $P.log exists; this step was run already"; exit 1; }

# Nothing else may use the GPUs, the port or the RAM.
[ "$(systemctl is-active ollama || true)" = inactive ] || { echo "ABORT: ollama is not inactive"; exit 1; }
apps=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader)
[ -z "$apps" ] || { echo "ABORT: processes on the GPUs: $apps"; exit 1; }
! curl -fs "$URL/health" > /dev/null 2>&1 || { echo "ABORT: something answers on $URL"; exit 1; }

sudo -v
{
  echo "date: $(date -u)"
  echo "model: $MODEL ($M)"
  echo "step: $STEP, reps: $REPS"
  "$BIN" --version 2>&1 | head -1
  echo "driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  echo "command: $BIN -m $M ${BASE[*]} ${STEP_OPTS[*]}"
} | tee "$P.cmd"

# Cold page cache: load time and the first requests read the model from the NVMe.
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

Q=timestamp,index,pstate,power.draw,temperature.gpu,memory.used,utilization.gpu,clocks.gr,clocks.mem
nvidia-smi --query-gpu=$Q --format=csv -lms 500 > "$P.gpu.csv" &
GPU_SAMPLER=$!
sudo -n scripts/cpu-power.sh "$P.cpu.csv" $$ &
CPU_SAMPLER=$!
SERVER=
# set +e: under set -e the first failing command ends the function, e.g. `kill` of a server
# that has already exited, and the samplers kept running (they once wrote into the next run).
cleanup() {
  set +e
  [ -z "$SERVER" ] || { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
  kill "$GPU_SAMPLER" "${RAM_SAMPLER:-}" 2>/dev/null || true
  sudo -n kill "$CPU_SAMPLER" 2>/dev/null || true
  sudo -n chown "$(id -u):$(id -g)" "$P.cpu.csv" 2>/dev/null || true
}
trap cleanup EXIT

t0=$(date +%s.%N)
"$BIN" -m "$M" "${BASE[@]}" "${STEP_OPTS[@]}" > "$P.log" 2>&1 < /dev/null &
SERVER=$!

# nvme_read_mib: read from the NVMe that holds the models since the run started (with mmap,
# experts that are not in the page cache are read from it while serving).
DISK=nvme0n1
sectors() { awk -v d=$DISK '$3 == d { print $6 }' /proc/diskstats; }
S0=$(sectors)
echo "utc_time,mem_available_mib,cached_mib,server_rss_mib,nvme_read_mib" > "$P.ram.csv"
while kill -0 "$SERVER" 2>/dev/null; do
  awk -v t="$(date -u +%T)" -v rss="$(awk '/^VmRSS/ { print int($2 / 1024) }' /proc/$SERVER/status 2>/dev/null)" \
      -v rd="$(( ($(sectors) - S0) / 2048 ))" \
    '/^MemAvailable/ { a = int($2 / 1024) } /^Cached/ { c = int($2 / 1024) }
     END { print t "," a "," c "," rss "," rd }' /proc/meminfo >> "$P.ram.csv"
  sleep 1
done &
RAM_SAMPLER=$!

ready=0
for _ in $(seq 1200); do
  if curl -fs "$URL/health" > /dev/null 2>&1; then ready=1; break; fi
  kill -0 "$SERVER" 2>/dev/null || break
  sleep 0.5
done
load_s=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN { print a - b }')
if [ $ready = 1 ]; then
  echo "== loaded in ${load_s} s; requests:"
  python3 scripts/client.py "$URL" "$MODEL" "$STEP" "$OUT/results.jsonl" "$REPS" "$load_s"
else
  echo "!! FAILED: server not ready after ${load_s} s; last lines of $P.log:"
  tail -n 20 "$P.log"
  exit 1
fi
echo "== peak VRAM per GPU (MiB):"
awk -F', ' 'NR > 1 { split($6, m, " "); if (m[1] > max[$2]) max[$2] = m[1] } END { for (g in max) print "  GPU" g ": " max[g] }' "$P.gpu.csv"
echo "== peak server RSS / page cache (MiB): $(awk -F, 'NR > 1 { if ($4 > r) r = $4; if ($3 > c) c = $3 } END { print r " / " c }' "$P.ram.csv")"
echo "== summary: scripts/summary.py"
