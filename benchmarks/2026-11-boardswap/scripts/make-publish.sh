#!/usr/bin/env bash
# Build the public copy of this benchmark for the ai-homelab repo:
#   publish/ai-homelab/benchmarks/2026-11-boardswap/
# Copies results, scripts, raw data, journal, engines.md and the checklist,
# then redacts what has no business in a public repo: Ollama's per-container
# public key, Docker-internal addresses (172.17.x.x) and the Ubuntu country
# mirror. Fails if any of them, a GPU UUID or a MAC address is still found.
# The folder README (publish/.../README.md) is written by hand and kept.
#
# Usage: scripts/make-publish.sh   (no sudo; only reads and writes in here)
set -euo pipefail
cd "$(dirname "$0")/.."

P=publish/ai-homelab/benchmarks/2026-11-boardswap
README=$(cat "$P/README.md" 2>/dev/null || true)
rm -rf "$P"
mkdir -p "$P"
cp -r results scripts before after "$P/"
cp journal.md engines.md AFTER-SWAP.md "$P/"
find "$P" -name '__pycache__' -prune -exec rm -rf {} +
[ -n "$README" ] && printf '%s\n' "$README" > "$P/README.md"

grep -rlE 'ssh-ed25519 |172\.17\.[0-9]+\.[0-9]+|bg\.archive\.ubuntu\.com' "$P" |
  xargs -r sed -i -E 's/ssh-ed25519 [A-Za-z0-9+\/=]+/ssh-ed25519 <redacted>/g;
                      s/172\.17\.[0-9]+\.[0-9]+/<docker-ip>/g;
                      s/bg\.archive\.ubuntu\.com/<mirror>.archive.ubuntu.com/g'

bad=$(grep -rlE 'ssh-ed25519 [A-Za-z0-9]|172\.17\.[0-9]|bg\.archive|GPU-[0-9a-fA-F]{8}-|([0-9a-f]{2}:){5}[0-9a-f]{2}' "$P" || true)
if [ -n "$bad" ]; then
  echo "NOT CLEAN:"; echo "$bad"; exit 1
fi
echo "ok: $(find "$P" -type f | wc -l) files, $(du -sh "$P" | cut -f1), redaction check clean"
