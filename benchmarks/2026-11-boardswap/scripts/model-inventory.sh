#!/usr/bin/env bash
# List the local Ollama models: tag, model blob (short digest), size, family,
# parameter count and quantization. Read-only; no sudo, no running Ollama needed.
set -euo pipefail

MODELS=${MODELS:-/usr/share/ollama/.ollama/models}

python3 - "$MODELS" <<'EOF'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
lib = root / "manifests/registry.ollama.ai/library"
blob = lambda d: root / "blobs" / d.replace(":", "-")

print(f'{"tag":38} {"blob":12} {"GiB":>5}  {"family":9} {"params":7} quant')
for f in sorted(p for p in lib.glob("*/*") if p.is_file()):
    m = json.loads(f.read_text())
    cfg = json.loads(blob(m["config"]["digest"]).read_text())
    layer = next(l for l in m["layers"]
                 if l["mediaType"].endswith("image.model"))
    tag = f"{f.parent.name}:{f.name}"
    print(f'{tag:38} {layer["digest"][7:19]:12} '
          f'{layer["size"] / 2**30:5.1f}  {cfg.get("model_family", ""):9} '
          f'{cfg.get("model_type", ""):7} {cfg.get("file_type", "")}')
EOF
