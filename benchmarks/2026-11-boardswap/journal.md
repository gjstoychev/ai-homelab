# Journal

Every step in the order it was run: why, the exact command, what was expected,
what came out. Raw output is in `before/` and `after/`; this file quotes only
the relevant parts.

Each entry uses this format: **Why**, **Command** (where it runs and whether it
needs sudo), **Expected**, **Actual**, **Verdict** (says plainly when a
prediction was wrong).

---

## Before the swap

### 0. Model inventory (2026-11-19)

**Why:** pick test models from what is already downloaded, and see which Ollama
tags share the same GGUF file so the same weights aren't benchmarked twice.

**Command** (z790, user shell, read-only, no sudo):

```bash
{ date -u; scripts/model-inventory.sh; } 2>&1 \
  | tee before/00-model-inventory.txt
```

**Actual:** 12 tags, 9 distinct GGUF files. `qwen25-64k`, `qwen27b-stable` and
`qwen3-64k` point to the same files as `qwen2.5:14b-instruct-q4_K_M`,
`qwen3.8:27b` and `qwen3:30b-a3b-instruct-2507-q4_K_M` (only the Modelfile
parameters differ). Everything is Q4_K_M except `llama3:8b` (Q4_0).

**Decisions:**

- Tested: translategemma 4b, llama3 8b, llama3.1 8b, qwen3 8b, qwen2.5 14b,
  qwen3 14b (fit one 16 GB card); qwen3.8 27b and qwen3 30b-a3b (both cards).
- The original Qwen3 30B-A3B is used, not the 2507 Instruct (same architecture
  and size, so the 2507 would only repeat the measurement).
- Planned extra: Qwen3 32B dense (~20 GB) as the largest model that needs both
  cards and still leaves room for the KV cache.
- The 27B (15.7 GiB) is not run on a single card: it would spill into system
  RAM and measure the CPU instead of the bus.

### 1. Versions (2026-11-19)

**Why:** record exact software versions and the GPU order before the swap, so
a different "after" number can be traced to the board and not to an update.

**Command** (z790, user shell, no sudo, writes one file):

```bash
cd ~/benchmarks/2026-11-boardswap
Q=index,name,pci.bus_id,driver_version
Q=$Q,vbios_version,power.limit,persistence_mode
{
  date -u
  uname -r
  nvidia-smi --query-gpu=$Q --format=csv
  ollama --version
  docker --version
} 2>&1 | tee before/01-versions.txt
```

The first try split the `--query-gpu` value across a `\` line break; pasting
indented the second half and nvidia-smi rejected it ("Option
vbios_version,power.limit,persistence_mode is not recognized"). Lesson: never
break a line inside an argument; build long values in a variable.

**Expected:** kernel 7.0.0-38-generic; GPU 0 = 01:00.0, GPU 1 = 02:00.0;
driver 580.178.04; same VBIOS and power limit (likely 180 W) on both;
persistence Enabled; Ollama 0.32.14; Docker 29.8.0.

**Actual:**

```
index, name, pci.bus_id, driver_version, vbios_version, power.limit [W], persistence_mode
0, NVIDIA GeForce RTX 5060 Ti, 00000000:01:00.0, 580.178.04, 98.06.4E.00.8B, 180.00 W, Enabled
1, NVIDIA GeForce RTX 5060 Ti, 00000000:02:00.0, 580.178.04, 98.06.4E.00.8B, 180.00 W, Enabled
```

Kernel 7.0.0-38-generic, Ollama 0.32.14, Docker 29.8.0 (build 88096ef).

**Verdict:** everything as expected. Both cards are identical down to the
VBIOS (98.06.4E.00.8B) and the 180 W limit, so a GPU0 vs GPU1 difference points
to the slot and link, not to the cards.

### 2. PCIe links per GPU and root port (2026-11-19)

**Why:** document link capability (LnkCap) and current status (LnkSta) of both
GPUs and their root ports. Only these lines are saved, so the GPU serial number
in the full `lspci -vv` output never lands in a file.

**Command** (z790, user shell, sudo for the extended config space, read-only):

```bash
cd ~/benchmarks/2026-11-boardswap
{
  date -u
  for d in 00:01.0 01:00.0 00:1b.0 02:00.0; do
    lspci -s "$d"
    sudo lspci -vv -s "$d" | grep -E 'LnkCap:|LnkSta:'
  done
} 2>&1 | tee before/02-pcie-links.txt
```

**Expected:** CPU root port 32GT/s x16, GPU0 32GT/s x8 running x8; chipset
root port 16GT/s x4, GPU1 32GT/s x8 running x4. All at 2.5GT/s while idle,
marked "(downgraded)".

**Actual:**

```
00:01.0 PCI bridge: Intel Corporation Device a70d (rev 01)
        LnkCap:    Port #2, Speed 32GT/s, Width x16, ASPM not supported
        LnkSta:    Speed 2.5GT/s, Width x8
01:00.0 VGA compatible controller: NVIDIA Corporation Device 2d04 (rev a1)
        LnkCap:    Port #0, Speed 32GT/s, Width x8, ASPM L1, Exit Latency L1 unlimited
        LnkSta:    Speed 2.5GT/s (downgraded), Width x8
00:1b.0 PCI bridge: Intel Corporation Raptor Lake PCI Express Root Port #21 (rev 11)
        LnkCap:    Port #21, Speed 16GT/s, Width x4, ASPM not supported
        LnkSta:    Speed 2.5GT/s, Width x4
02:00.0 VGA compatible controller: NVIDIA Corporation Device 2d04 (rev a1)
        LnkCap:    Port #0, Speed 32GT/s, Width x8, ASPM L1, Exit Latency L1 unlimited
        LnkSta:    Speed 2.5GT/s (downgraded), Width x4 (downgraded)
```

**Verdict:** values as expected; one detail wrong: lspci marks "(downgraded)"
only on the device (GPU) side of a link, not on the root port side.

What it means: GPU0 can reach Gen5 x8 (~31.5 GB/s per direction in theory).
GPU1 is capped by its root port at Gen4 x4 (~7.9 GB/s), and that traffic also
shares the chipset's DMI uplink (Gen4 x8 on Z790) with NVMe, NICs etc. On paper
GPU1 has about a quarter of GPU0's bandwidth. The 2.5GT/s is idle power saving;
speed under load is step 11.

### 3. GPU topology and P2P status (2026-11-19)

**Why:** see the path between the GPUs as the driver reports it, and whether
peer-to-peer works. Without P2P, every GPU-to-GPU transfer in layer and row
split goes through host RAM, so GPU1's x4 link is involved every time.

**Command** (z790, user shell, no sudo, read-only):

```bash
cd ~/benchmarks/2026-11-boardswap
{
  date -u
  nvidia-smi topo -m
  echo
  nvidia-smi topo -p2p r
} 2>&1 | tee before/03-topology.txt
```

**Expected:** GPU0<->GPU1 `PHB` (possibly `NODE`), CPU affinity 0-27,
NUMA 0; P2P read `NS` (P2P is disabled on GeForce).

**Actual** (legends omitted, see the raw file):

```
    GPU0    GPU1    CPU Affinity    NUMA Affinity    GPU NUMA ID
GPU0     X     PHB    0-27    0        N/A
GPU1    PHB     X     0-27    0        N/A

     GPU0    GPU1
 GPU0    X    CNS
 GPU1    CNS    X
```

**Verdict:** path and affinity as expected. P2P was wrong in detail: the
driver reports `CNS` (chipset not supported), not `NS`, so it blames the
platform, not the GeForce card. The practical result is the same: no P2P.
After the swap: check whether the reason stays `CNS` on the Z690.

### 4. Idle power per GPU (2026-11-19)

**Why:** baseline idle state of both cards before any benchmark (power,
temperature, fan, clocks, VRAM used, current link), and proof that no model is
loaded by the Ollama service.

**Command** (z790, user shell, no sudo, read-only, 60 s):

```bash
cd ~/benchmarks/2026-11-boardswap
Q=timestamp,index,pstate,power.draw,temperature.gpu
Q=$Q,fan.speed,memory.used,clocks.gr,clocks.mem
Q=$Q,pcie.link.gen.current,pcie.link.width.current
{
  date -u
  ollama ps
  timeout 60 nvidia-smi --query-gpu=$Q --format=csv -l 1
} 2>&1 | tee before/04-idle-power.txt
```

Summary (Claude, read-only):

```bash
scripts/idle-summary.py before/04-idle-power.txt \
  | tee before/04-idle-power-summary.txt
```

**Expected:** `ollama ps` empty; P8; 5-12 W per card (GPU0 a bit higher if it
drives a display); 30-45 °C; fan 0 %; < 500 MiB used; Gen1 x8 / Gen1 x4.

**Actual** (60 samples per GPU):

| GPU | W avg | W min-max | °C | VRAM used | pstate | fan | link |
|---|---|---|---|---|---|---|---|
| 0 | 10.65 | 10.55-10.75 | 35 | 12 MiB | P8 | 0 % | Gen1 x8 |
| 1 | 9.04 | 8.90-9.12 | 29 | 2 MiB | P8 | 0 % | Gen1 x4 |

`ollama ps` showed no loaded model.

**Verdict:** as expected, except GPU1's temperature (29 °C), 1 °C below the
predicted range. Both cards together idle at ~19.7 W, very stable (±0.1 W).
GPU0 draws 1.6 W and 10 MiB more, consistent with being the boot VGA (console
framebuffer). GPU1 is 6 °C cooler, probably slot position/airflow plus the
lower power (not proven); compare after the swap, when the slots change.

### 5. Download Qwen3 32B (2026-11-19)

**Why:** a dense model that does not fit one 16 GB card, so it must use both;
the heaviest case for layer and especially row split (all weights are used for
every token, unlike the 30B-A3B MoE with ~3B active).

**Command** (z790, user shell, no sudo; the Ollama service downloads into its
model store, ~20 GB added, service configuration unchanged):

```bash
time ollama pull qwen3:32b
```

**First try** failed after 0.6 s:

```
Error: pull model manifest: file does not exist
```

Diagnosis: in Ollama this error means the registry answered 404 to the
manifest request. A manual check from the user's shell returned 200 for
`32b` and for two known tags:

```bash
for t in 32b 30b-a3b 14b; do
  printf '%-8s ' "$t"
  curl -s -o /dev/null -w '%{http_code}\n' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry.ollama.ai/v2/library/qwen3/manifests/$t"
done
```

The service unit showed no network restriction or proxy. The retry worked, so
the 404 was most likely transient on the registry side (a typo in the first
command cannot be ruled out). Not done on purpose: test-pulling a tag that is
already present, because an updated manifest would replace the local files
that are being benchmarked.

**Expected:** download of ~20 GB; inventory shows qwen3, 32.8B, Q4_K_M,
~18.5-19 GiB; manifest ID `030ee887880f` as on ollama.com/library/qwen3/tags;
~17-18 min at the initial 19 MB/s.

**Actual:** `success`, real time 13m11s (average ~25 MB/s). Verification
(Claude, read-only):

```bash
{ date -u; scripts/model-inventory.sh; } 2>&1 \
  | tee before/05-model-inventory.txt
M=/usr/share/ollama/.ollama/models/manifests/registry.ollama.ai/library
sha256sum "$M/qwen3/32b" | cut -c1-12
```

```
qwen3:32b    3291abe70f16  18.8  qwen3     32.8B   Q4_K_M
030ee887880f
```

**Verdict:** model as expected (18.8 GiB = 20,201,240,160 bytes), manifest ID
matches the registry page. The download time was wrong: 13 min instead of
17-18, because the speed rose after the start.

### 6a. NVIDIA repo signing key (2026-11-19)

**Why:** apt accepts packages from NVIDIA's container toolkit repo only with
its key. The fingerprint is recorded so it can be checked.

**Command** (z790, user shell, sudo; writes one keyring file, apt sources not
touched yet):

```bash
cd ~/benchmarks/2026-11-boardswap
K=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o "$K"
gpg --show-keys "$K" 2>&1 | tee before/06a-nvidia-repo-key.txt
```

**Expected:** `pub rsa4096`, uid "NVIDIA CORPORATION (Open Source Projects)
<cudatools@nvidia.com>", fingerprint ending in `DDCA E044 F796 ECB0` (from
memory, not certain).

**Actual:**

```
pub   rsa4096 2017-09-28 [SCE]
      C95B321B61E88C1809C4F759DDCAE044F796ECB0
uid                      NVIDIA CORPORATION (Open Source Projects) <cudatools@nvidia.com>
sub   rsa2048 2019-09-18 [S] [expired: 2021-06-16]
```

**Verdict:** key as expected. Not predicted: an expired signing subkey
(harmless, the primary key has no expiry and can sign itself, `[SCE]`), and
`gpg --show-keys` created an empty `~/.gnupg` (side effect, no keys imported).

### 6b. NVIDIA repo in apt (2026-11-19)

**Why:** tell apt where the container toolkit packages come from. `signed-by`
binds this repo to the key from 6a (and the key to this repo only).

**Command** (z790, user shell, sudo; writes
`/etc/apt/sources.list.d/nvidia-container-toolkit.list`, nothing installed):

```bash
cd ~/benchmarks/2026-11-boardswap
K=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
U=https://nvidia.github.io/libnvidia-container
L=/etc/apt/sources.list.d/nvidia-container-toolkit.list
curl -fsSL "$U/stable/deb/nvidia-container-toolkit.list" |
  sed "s#deb https://#deb [signed-by=$K] https://#g" |
  sudo tee "$L" |
  tee before/06b-nvidia-repo-list.txt
```

The first try used `\` line continuations with the `|` at the start of the next
line. The paste added a space after one `\`, so bash read an escaped space:
`sed: can't read  : No such file or directory` and `syntax error near
unexpected token '|'`. `sudo tee` never ran, nothing was changed. Lesson: end
pipeline lines with `|`; bash continues by itself and trailing spaces are
harmless.

**Expected:** one active `stable` line with `signed-by`, possibly a commented
`experimental` line; `$(ARCH)` literal (apt substitutes it).

**Actual:**

```
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/experimental/deb/$(ARCH) /
```

**Verdict:** as expected; the file in `/etc/apt/sources.list.d/` is identical
to the saved copy.

### 6c. apt-get update and toolkit version (2026-11-19)

**Why:** first read of the new repo: does apt accept its signature, and which
toolkit version would be installed.

**Command** (z790, user shell, sudo for the update; refreshes package lists,
installs nothing):

```bash
cd ~/benchmarks/2026-11-boardswap
{
  sudo apt-get update
  apt-cache policy nvidia-container-toolkit
} 2>&1 | tee before/06c-apt-update.txt
```

**Expected:** `Get:` lines for the nvidia.github.io InRelease and Packages, no
`NO_PUBKEY`/`EXPKEYSIG` errors, "Reading package lists... Done"; installed
(none), candidate 1.17 or newer (a guess).

**Actual** (NVIDIA lines; the other repos were `Hit:`):

```
Get:5 https://nvidia.github.io/libnvidia-container/stable/deb/amd64  InRelease [1477 B]
Get:8 https://nvidia.github.io/libnvidia-container/stable/deb/amd64  Packages [29.0 kB]
Reading package lists...
nvidia-container-toolkit:
  Installed: (none)
  Candidate: 1.20.2-1
```

**Verdict:** as expected, no signature errors (the repo is signed with the
primary key, so the expired subkey from 6a does not matter). Minor miss: apt
prints no "Done" when its output goes into a pipe. Version 1.20.2-1 is
installed pinned in 6d and must be unchanged after the swap.

### 6d. Install nvidia-container-toolkit 1.20.2-1 (2026-11-19)

**Why:** lets Docker containers use the GPUs (`--gpus`). The version is pinned
so the setup is repeatable and can be compared after the swap.

**Command** (z790, user shell, sudo; installs packages only, Docker config,
driver and kernel modules untouched):

```bash
cd ~/benchmarks/2026-11-boardswap
V=1.20.2-1
{
  sudo apt-get install -y nvidia-container-toolkit=$V
  dpkg -l | grep -E 'nvidia-container|libnvidia-container'
} 2>&1 | tee before/06d-install.txt
```

Check (Claude, read-only): `grep -A6 'nvidia-container-toolkit=1.20.2-1'
/var/log/apt/history.log`

**Expected:** exactly 4 new packages (nvidia-container-toolkit,
nvidia-container-toolkit-base, libnvidia-container-tools,
libnvidia-container1), all 1.20.2-1; no driver/DKMS/kernel packages.

**Actual:**

```
0 upgraded, 4 newly installed, 0 to remove and 91 not upgraded.
Install: libnvidia-container1:amd64 (1.20.2-1, automatic), libnvidia-container-tools:amd64 (1.20.2-1, automatic), nvidia-container-toolkit:amd64 (1.20.2-1), nvidia-container-toolkit-base:amd64 (1.20.2-1, automatic)
```

needrestart: no services, containers or sessions need a restart.

**Verdict:** as expected. Note: 91 packages are pending upgrades; no
`apt upgrade` until the after-swap measurements are done, so kernel, driver
and Docker stay identical.

### 7. NVIDIA runtime in Docker (2026-11-19)

**Why:** register the `nvidia` runtime in Docker's config; Docker reads it only
on restart. Container list before/after to see whether SearXNG comes back.

**Command** (z790, user shell, sudo; creates `/etc/docker/daemon.json`,
restarts Docker, SearXNG down for a few seconds; Ollama service unaffected):

```bash
cd ~/benchmarks/2026-11-boardswap
{
  sudo docker ps --format '{{.Names}} {{.Status}}'
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo cat /etc/docker/daemon.json
  sudo systemctl restart docker
  sleep 5
  sudo docker ps --format '{{.Names}} {{.Status}}'
  sudo docker info --format '{{json .Runtimes}}'
} 2>&1 | tee before/07-docker-runtime.txt
```

**Expected:** SearXNG up before; nvidia-ctk creates the config; daemon.json
with only `runtimes.nvidia` (maybe CDI keys); SearXNG back after the restart
if it has a restart policy; runtimes include `nvidia`.

**Actual:**

```
searxng Up About an hour
level=info msg="Config file does not exist; using empty config"
level=info msg="Wrote updated config to /etc/docker/daemon.json"
level=info msg="It is recommended that docker daemon be restarted."
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }
}
searxng Up 5 seconds
```

Runtimes: `io.containerd.runc.v2` (runc), `nvidia` (nvidia-container-runtime),
`runc` (runc 1.5.1).

**Verdict:** as expected; no CDI keys added. SearXNG has a restart policy and
came back by itself. Miss on my side: `{{json .Runtimes}}` dumps every
runtime's full feature list; use
`--format '{{range $k, $v := .Runtimes}}{{$k}}={{$v.Path}} {{end}}'` next time.

### 8. GPU smoke test in Docker (2026-11-19)

**Why:** prove the chain Docker -> nvidia runtime -> driver -> both GPUs works
inside a container; record the image digest so the identical image runs after
the swap. `nvidia-smi -L` is avoided on purpose (prints GPU UUIDs).

**Command** (z790, user shell, sudo; pulls one image, containers removed):

```bash
cd ~/benchmarks/2026-11-boardswap
I=nvidia/cuda:13.0.0-base-ubuntu24.04
Q=index,name,pci.bus_id,driver_version
{
  sudo docker run --rm --gpus all "$I" nvidia-smi
  sudo docker run --rm --gpus all "$I" nvidia-smi --query-gpu=$Q --format=csv
  sudo docker image inspect "$I" --format '{{index .RepoDigests 0}}'
} 2>&1 | tee before/08-docker-gpu-smoke.txt
```

**Expected:** driver 580.178.04 / CUDA 13.0 inside the container; both GPUs,
same order as on the host; P8, ~9-11 W, no processes; an image digest.

**Actual** (excerpt):

```
| NVIDIA-SMI 580.178.04             Driver Version: 580.178.04     CUDA Version: 13.0     |
|   0  NVIDIA GeForce RTX 5060 Ti     On  |   00000000:01:00.0  On |                  N/A |
|  0%   35C    P8             10W /  180W |      12MiB /  16311MiB |      0%      Default |
|   1  NVIDIA GeForce RTX 5060 Ti     On  |   00000000:02:00.0 Off |                  N/A |
|  0%   29C    P8              9W /  180W |       2MiB /  16311MiB |      0%      Default |
0, NVIDIA GeForce RTX 5060 Ti, 00000000:01:00.0, 580.178.04
1, NVIDIA GeForce RTX 5060 Ti, 00000000:02:00.0, 580.178.04
nvidia/cuda@sha256:6e43a6b02e5f16e4a715953be8b29c40acbe84aed11a61357ef0fc899967fbd9
```

**Verdict:** as expected. GPU0 shows `Disp.A On` (GPU1 `Off`): it drives the
display/console, which confirms the explanation for its extra 1.6 W and 10 MiB
at idle in step 4.

### 9. Build nvbandwidth (2026-11-19)

**Why:** nvbandwidth is NVIDIA's bus bandwidth benchmark (host<->GPU,
GPU<->GPU). It must be compiled; that happens in the official CUDA 13.0 devel
image for sm_120 only. The image is kept and re-run unchanged after the swap.

**Recipe:** `scripts/nvbandwidth/Dockerfile` (build tools, newest release tag
cloned and recorded in `/nvbandwidth-version.txt`, cmake with
`CMAKE_CUDA_ARCHITECTURES=120`, binary as entrypoint).

**Command** (z790, user shell, sudo; pulls the CUDA devel image, builds a local
image, host unchanged):

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/nvbandwidth:cuda13.0.0
B=nvidia/cuda:13.0.0-devel-ubuntu24.04
{
  sudo docker build --progress=plain -t "$T" scripts/nvbandwidth
  sudo docker run --rm --entrypoint cat "$T" /nvbandwidth-version.txt
  sudo docker image inspect "$B" --format '{{index .RepoDigests 0}}'
  sudo docker image inspect "$T" --format '{{.Id}}'
} 2>&1 | tee before/09-nvbandwidth-build.txt
```

**Expected:** successful build for arch 120; nvbandwidth v0.8 or newer (a
guess); digest of the devel image; ID of the built image.

**Actual:**

```
#4 [1/5] FROM docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04@sha256:1e8ac7a54c184a1af8ef2167f28fa98281892a835c981ebcddb1fad04bdd452d
#8 0.235 -- CMAKE_CUDA_ARCHITECTURES set by user: 120
#8 6.732 [100%] Linking CXX executable nvbandwidth
#9 naming to docker.io/local/nvbandwidth:cuda13.0.0 done
nvbandwidth v0.11.0 201eaf7f25eda954d08a7c4fed9d8325e3c32ddf 2026-11-10
Error response from daemon: No such image: nvidia/cuda:13.0.0-devel-ubuntu24.04
sha256:fec213b5a3bf47b9abdbb68e34873be834ab88b3ccb3ea1638bc217a242923d3
```

Base image download took ~3 min (#4, 183 s), compile ~7 s.

**Verdict:** build as expected; nvbandwidth v0.11.0. Wrong: the devel image
digest lookup. With Docker 29, a base image pulled by `docker build` lives
only in the build cache, not under its name in the image store. The digest is
taken from the build log instead (`sha256:1e8ac7a5...`). Two harmless warnings:
a CMake developer warning (CMP0135) and a ca-certificates rehash note.

### 10. Bus bandwidth with nvbandwidth (2026-11-19)

**Why:** the central raw measurement: real GB/s over each GPU's link, per GPU,
both directions, and both GPUs at once (do they get in each other's way?).
GPU<->GPU tests are waived (no P2P, step 3).

**Command** (z790, user shell, sudo for Docker; measures only, no downloads or
other load running):

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/nvbandwidth:cuda13.0.0
{
  date -u
  ollama ps
  sudo docker run --rm --gpus all "$T"
} 2>&1 | tee before/10-nvbandwidth.txt
```

CSV (Claude, read-only):

```bash
scripts/nvbw-to-csv.py before/10-nvbandwidth.txt \
  > results/nvbandwidth-before.csv
```

**Expected:** copy engine (CE) host->device and device->host ~25-28 GB/s on
GPU0 (Gen5 x8, 31.5 theoretical), ~6-7 GB/s on GPU1 (Gen4 x4, 7.9
theoretical), so roughly 4x; both GPUs at once about as fast as alone (GPU1's
x4 is narrower than the ~15.8 GB/s DMI uplink); device<->device waived.

**Actual** (CE unless noted; all coefficients of variation < 3.3 %):

| Test | GPU0 | GPU1 | GPU0:GPU1 |
|---|---|---|---|
| host -> device | 20.27 GB/s | 7.15 GB/s | 2.8x |
| device -> host | 17.29 GB/s | 7.26 GB/s | 2.4x |
| bidirectional, host->device part | 7.93 GB/s | 4.81 GB/s | |
| bidirectional, device->host part | 15.14 GB/s | 6.69 GB/s | |
| both GPUs at once, host -> GPUs | 18.96 GB/s (-6 %) | 5.76 GB/s (-19 %) | |
| both GPUs at once, GPUs -> host | 16.37 GB/s (-5 %) | 5.29 GB/s (-27 %) | |
| host<->device latency (SM) | 612 ns | 1191 ns | |
| local VRAM copy / read | 386 / 428 GB/s | 386 / 428 GB/s | |

Full table: `results/nvbandwidth-before.csv`.

**Verdict:** GPU1 as expected, GPU0 and the simultaneous case wrong.

- GPU0 reaches only ~64 % of Gen5 x8 theory (expected 80-90 %). It is above
  the Gen4 x8 maximum (15.75 GB/s), so the link is faster than Gen4, but
  something besides link width limits it. Link state under load: step 11.
- GPU1 uses ~91-92 % of Gen4 x4: the x4 link is saturated, but the real gap to
  GPU0 is ~2.5-3x, not 4x.
- With both GPUs busy, GPU1 loses 19-27 %, GPU0 only 5-6 %. GPU1's 5-7 GB/s is
  far below the DMI uplink, so the contention is on the shared path to host
  memory (DMI, CPU side, or how nvbandwidth runs concurrent copies; not
  separable here). After the swap: if GPU1 holds its speed with both busy, the
  chipset path was the cause.
- Not predicted: GPU1 has twice GPU0's host latency (1191 vs 612 ns, the
  chipset hop). Token generation moves only a few KB per token between the
  cards (layer split) or does many small syncs (row split), so latency may
  matter more than bandwidth there.
- Both cards' VRAM bandwidth is identical: the cards are the same, only the
  slot differs.

### 11. PCIe link speed and width under load (2026-11-19)

**Why:** idle links run at 2.5 GT/s; check what they train to under load, and
whether GPU0's link explains its ~20 GB/s in step 10.

**Command** (z790, user shell, sudo for Docker; measures only):

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/nvbandwidth:cuda13.0.0
Q=timestamp,index,pstate,pcie.link.gen.current,pcie.link.width.current
Q=$Q,pcie.link.gen.max,pcie.link.width.max,power.draw,clocks.mem
{
  nvidia-smi --query-gpu=$Q --format=csv -lms 200 \
    > before/11-link-samples.csv &
  sudo docker run --rm --gpus all "$T" -t host_to_all_memcpy_ce -i 10
  kill $!
} 2>&1 | tee before/11-link-under-load.txt
```

Summary (Claude, read-only):

```bash
scripts/link-summary.py before/11-link-samples.csv \
  | tee before/11-link-summary.txt
```

**Expected:** ~19 / 5.8 GB/s as in step 10; under load GPU0 Gen5 x8, GPU1
Gen4 x4; max 5/8 and 4/4 (or 5/8 for GPU1 if the card's own max is shown);
~15-20 s of load.

**Actual:**

```
host_to_all_memcpy_ce: GPU0 18.99 GB/s, GPU1 5.76 GB/s (CV 0.25 %)
GPU0:
   273 samples  P1  Gen5 x8  (max Gen5 x8)  mem 13801 MHz
     6 samples  P8  Gen1 x8  (max Gen5 x8)  mem 405 MHz
  under load: 273 samples, 19:08:17.926 .. 19:09:12.364, power avg 35.0 W, max 41.5 W
GPU1:
   273 samples  P1  Gen4 x4  (max Gen4 x8)  mem 13801 MHz
     6 samples  P8  Gen1 x4  (max Gen4 x8)  mem 405 MHz
  under load: 273 samples, 19:08:17.926 .. 19:09:12.364, power avg 36.9 W, max 38.2 W
```

**Verdict:** links as expected: GPU0 Gen5 x8, GPU1 Gen4 x4 under load, no
drops during the run. Bandwidth reproduces step 10 within 0.2 %. Wrong
details: GPU1's max is reported as "Gen4 x8" (generation limited by the root
port, width the card's own), and the load lasted ~55 s, not 15-20 s.

Conclusion for step 10: GPU0's link really runs at Gen5 x8, so the link is not
why GPU0 reaches only ~20 of ~31.5 GB/s. The limit is elsewhere (host/CPU side,
the card's copy engine, or the default 512 MiB buffer); not determined here.

### 12a. llama.cpp image: fetch and inspect (2026-11-19)

**Why:** get the digest (so every later command pins exactly this image), the
build number, the binary layout, and whether llama.cpp's CUDA backend sees
both GPUs. The `full-cuda` variant contains `llama-bench`.

**Command** (z790, user shell, sudo; pulls a large image, host unchanged):

```bash
cd ~/benchmarks/2026-11-boardswap
I=ghcr.io/ggml-org/llama.cpp:full-cuda
C='ls /app; /app/llama-cli --version; /app/llama-cli --list-devices'
{
  sudo docker pull "$I"
  sudo docker image inspect "$I" --format '{{index .RepoDigests 0}}'
  sudo docker run --rm --gpus all --entrypoint sh "$I" -c "$C"
} 2>&1 | tee before/12a-llamacpp-image.txt
```

**Expected:** a digest; `/app` with `llama-bench`, `llama-cli`,
`llama-server` and a CUDA backend library; a build number (guess: > 7000);
CUDA0 and CUDA1 as RTX 5060 Ti.

**Actual** (binary list shortened):

```
ghcr.io/ggml-org/llama.cpp@sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949
libggml-cuda.so, libggml-cpu-<variant>.so (alderlake ... zen4), llama-bench,
llama-cli, llama-server, ...
version: 1.0.0-dev (build 12464, commit d3c3e242c)
built with GNU 14.2.0 for Linux x86_64
Available devices:
  CUDA0: NVIDIA GeForce RTX 5060 Ti (15838 MiB, 15691 MiB free)
  CUDA1: NVIDIA GeForce RTX 5060 Ti (15847 MiB, 15710 MiB free)
```

**Verdict:** as expected; build 12464 (commit d3c3e242c). All later commands
use the image by digest, not by the moving `full-cuda` tag. CUDA0 has ~19 MiB
less free memory than CUDA1 (the display framebuffer, see step 8). Whether the
kernels actually run on sm_120 needs a real run (12b).

The model list for all benchmark scripts is in `scripts/models.tsv` (key,
Ollama tag, full blob name, fit single/dual).

### 12b. llama.cpp check: Blackwell kernels and qwen35 (2026-11-19)

**Why:** the device list only proves the CUDA backend loads; a real run proves
the image has kernels for sm_120. Also: does this build support the `qwen35`
architecture of the 27B? Tiny workload, one repetition, not a benchmark.

**Command** (z790, user shell, sudo for Docker; models mounted read-only):

```bash
cd ~/benchmarks/2026-11-boardswap
D=sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949
I=ghcr.io/ggml-org/llama.cpp@$D
B=/usr/share/ollama/.ollama/models/blobs
M=/models/sha256-
M1=${M}667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29
M2=${M}f5f1dd8920d417aac2718b0bda3403da274301efdd6760b4f0f4b864ff2ad57d
A=(--rm --gpus all -v "$B":/models:ro --entrypoint /app/llama-bench)
{
  date -u
  ollama ps
  sudo docker run "${A[@]}" "$I" -m "$M1" -m "$M2" -p 64 -n 16 -r 1
} 2>&1 | tee before/12b-llamacpp-check.txt
```

**Expected:** 2 devices with compute capability 12.0; llama 8B tg16 ~60-75
t/s, qwen35 27B tg16 ~15-22 t/s (both cards); or an error for sm_120 kernels or
the qwen35 architecture.

**Actual:**

```
ggml_cuda_init: found 2 CUDA devices (Total VRAM: 31686 MiB):
  Device 0: NVIDIA GeForce RTX 5060 Ti, compute capability 12.0, VMM: yes, VRAM: 15838 MiB
  Device 1: NVIDIA GeForce RTX 5060 Ti, compute capability 12.0, VMM: yes, VRAM: 15847 MiB
| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| llama 8B Q4_K - Medium         |   4.58 GiB |     8.03 B | CUDA       |  -1 |            pp64 |       2518.00 ± 0.00 |
| llama 8B Q4_K - Medium         |   4.58 GiB |     8.03 B | CUDA       |  -1 |            tg16 |         83.79 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.65 GiB |    27.32 B | CUDA       |  -1 |            pp64 |        818.83 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.65 GiB |    27.32 B | CUDA       |  -1 |            tg16 |         24.03 ± 0.00 |
build: d3c3e242c (12464)
```

**Verdict:** both work: sm_120 kernels run, `qwen35` is supported, so the 27B
runs on both engines. My t/s guesses were too low: 83.8 instead of 60-75 for
the 8B, 24.0 instead of 15-22 for the 27B. Both are ~90 % of the rough upper
bound (VRAM bandwidth 448 GB/s divided by model size: ~91 and ~27 t/s), so
generation here is memory-bound as expected. This build shows `ngl -1` as its
default; the benchmarks set `-ngl 99` explicitly.

### 13. Benchmark scripts (2026-11-19)

**Why:** ~50 runs must be identical before and after the swap, so they are
scripted. Written by Claude, reviewed by the user before the first run.

- `scripts/models.tsv`: the 9 models (key, Ollama tag, full blob name,
  single/dual).
- `scripts/bench-llamacpp.sh before|after single|dual`: llama-bench, image by
  digest (build 12464), models read-only. Single-card models: gpu0, gpu1
  (`--gpus device=N`, the other card is invisible), layer and row split on both
  cards; dual models: layer and row. Per run `-ngl 99 -fa 1 -p 512 -n 128 -r 5`
  (pp512, tg128, 5 repetitions). One JSONL file per run, Markdown table in the
  log, GPU samples every 500 ms in a CSV.
- `scripts/bench-ollama.sh before|after` with `scripts/ollama-client.py`:
  Ollama 0.32.14 in Docker on port 11435, models mounted read-only, a fresh
  container per run. Single-card models: gpu0, gpu1, spread
  (`OLLAMA_SCHED_SPREAD=1`); dual models: spread. Request 0 loads the model
  (load time); 5 measured requests, each starting with a different request
  number so the prompt is never served from the KV cache. `raw=true` (no chat
  template, no thinking), ~500-token prompt, 128 generated tokens, temperature
  0, flash attention on. Server logs saved with GPU UUIDs redacted.
- Both scripts abort if the host's Ollama service has a model loaded.

Known differences between the engines, on purpose: llama-bench processes a
synthetic 512-token prompt, Ollama the ~500-token text (exact count recorded);
Ollama allocates a 4096-token context. Both measure tokens per second for
prompt processing and generation.

### 14. llama-bench, single-card models (2026-11-19, first run)

**Why:** pp512 and tg128 for the six models that fit one card, on GPU0 alone,
GPU1 alone, layer split and row split. Core of the before/after comparison.

**Command** (z790, user shell; the script calls sudo docker, reads models
read-only, writes to `before/`; 24 runs, 19:25-19:31 UTC):

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/bench-llamacpp.sh before single
```

Summary (Claude, read-only):

```bash
scripts/llamabench-summary.py results/llamabench-before.csv \
  before/14-llamabench | tee before/14-llamabench-summary.txt
```

**Expected:** tg on GPU0 ~ GPU1 (within a few %), layer split slightly below a
single card, row split clearly slower (and slower here because of GPU1's x4).

**Actual** (t/s, mean of 5 repetitions):

| Model | pp512 GPU0 | GPU1 | layer | tg128 GPU0 | GPU1 | layer |
|---|---|---|---|---|---|---|
| llama3 8B (Q4_0) | 4254.6 | 4270.2 | 4284.0 | 90.4 | 90.0 | 89.9 |
| llama3.1 8B | 4063.9 | 4028.9 | 4048.6 | 84.6 | 84.2 | 84.0 |
| qwen3 8B | 3953.3 | 3915.9 | 3930.3 | 79.9 | 79.4 | 79.3 |
| qwen2.5 14B | 2154.5 | 2129.9 | 2151.8 | 45.0 | 44.9 | 44.9 |
| qwen3 14B | 2159.5 | 2141.8 | 2153.1 | 44.7 | 44.6 | 44.5 |

All standard deviations < 2 % except llama3 8B pp512 on GPU0 (±3.3 %).

Failures:

- translategemma 4B, all configs: `error loading model hyperparameters: key
  not found in model: gemma3.attention.layer_norm_rms_epsilon`. Ollama's own
  converter wrote this GGUF without a key llama.cpp requires (Ollama's engine
  uses a default). Ollama-only model.
- Row split, all models: `llama_model_load: error loading model: device CUDA0
  does not support split buffers`. Cause unknown; diagnosis in 14b.

**Verdict:** GPU0 vs GPU1 as expected: generation differs by at most 0.6 %,
prompt processing by at most 1.2 %; with the model resident in VRAM almost
nothing crosses the bus. Layer split costs at most 0.7 % against a single card:
for models that fit one card, the x4 link makes no measurable difference in
layer mode. Not expected: row split does not load at all in this build, and the
translategemma file is not readable by llama.cpp.

### 14b. Row split diagnosis (2026-11-19)

**Why:** row split failed for every model in step 14. Check which split modes
this build offers and whether flash attention is the cause.

**Command** (z790, user shell, sudo for Docker; reads only):

```bash
cd ~/benchmarks/2026-11-boardswap
D=sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949
I=ghcr.io/ggml-org/llama.cpp@$D
B=/usr/share/ollama/.ollama/models/blobs
M=/models/sha256-
M=${M}667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29
A=(--rm --gpus all -v "$B":/models:ro --entrypoint /app/llama-bench)
{
  sudo docker run "${A[@]}" "$I" --help | grep -iE -A3 'split|-sm|-fa'
  sudo docker run "${A[@]}" "$I" -m "$M" -sm row -fa 0 -p 64 -n 16 -r 1
} 2>&1 | tee before/14b-row-diagnosis.txt
```

**Expected:** split modes `none|layer|row`, perhaps a newer one (unknown);
row with `-fa 0` either works (FA was the cause) or fails the same way.

**Actual:**

```
  -sm, --split-mode <none|layer|row|tensor>         (default: layer)
  -fa, --flash-attn <on|off|auto>                   (default: auto)
llama_model_load: error loading model: device CUDA0 does not support split buffers
```

**Verdict:** flash attention is not the cause: row split fails the same way
with `-fa 0`. This build has a fourth mode, `tensor`, which I did not know.
`row` is still listed but the CUDA backend in this build does not provide the
split buffers it needs. `-fa` now takes on/off/auto; the `-fa 1` used in step
14 was accepted (JSONL shows `flash_attn: 1`). Next: test `-sm tensor` as the
tensor-parallel (heavy PCIe traffic) configuration.

### 14c. Tensor split check (2026-11-19)

**Why:** `-sm tensor` might replace the broken `row` as the tensor-parallel
configuration (heavy PCIe traffic).

**Command** (z790, user shell, sudo for Docker; reads only):

```bash
cd ~/benchmarks/2026-11-boardswap
D=sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949
I=ghcr.io/ggml-org/llama.cpp@$D
B=/usr/share/ollama/.ollama/models/blobs
M=/models/sha256-
M=${M}667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29
A=(--rm --gpus all -v "$B":/models:ro --entrypoint /app/llama-bench)
{
  date -u
  sudo docker run "${A[@]}" "$I" -m "$M" -sm tensor -fa on -p 64 -n 16 -r 1
} 2>&1 | tee before/14c-tensor-check.txt
```

**Expected:** unknown mode; if it works, tg16 below the single-card 84 t/s.

**Actual:**

```
CUDA error: unhandled cuda error (run with NCCL_DEBUG=INFO for details)
  current device: 1, in function ggml_backend_cuda_comm_allreduce_nccl at /app/ggml/src/ggml-cuda/ggml-cuda.cu:1390
  ncclGroupEnd()
```

**Verdict:** the model loads, the first computation crashes in NCCL (NVIDIA's
GPU communication library, used by tensor mode for the allreduce between the
cards). Without P2P, NCCL goes through host memory, usually via `/dev/shm`,
and Docker gives containers only 64 MB of it. Suspected, not proven. Next:
same test with `--shm-size=1g` and `NCCL_DEBUG=INFO`.

### 14d. Tensor split with more shared memory and NCCL logging (2026-11-19)

**Why:** test whether Docker's 64 MB `/dev/shm` broke NCCL in 14c; if not,
NCCL's own log should name the cause.

**Command** (z790, user shell, sudo for Docker; reads only; differs from 14c
only by `--shm-size=1g` and `NCCL_DEBUG=INFO`):

```bash
cd ~/benchmarks/2026-11-boardswap
D=sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949
I=ghcr.io/ggml-org/llama.cpp@$D
B=/usr/share/ollama/.ollama/models/blobs
M=/models/sha256-
M=${M}667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29
A=(--rm --gpus all -v "$B":/models:ro --entrypoint /app/llama-bench)
A+=(--shm-size=1g -e NCCL_DEBUG=INFO)
{
  date -u
  sudo docker run "${A[@]}" "$I" -m "$M" -sm tensor -fa on -p 64 -n 16 -r 1
} 2>&1 | tee before/14d-tensor-nccl.txt
```

(The first attempt was not run; the command was missed, not failed.)

**Expected:** NCCL log; with enough shm either a working run with transport
SHM (not P2P), or the same crash with an `NCCL WARN` naming the cause.

**Actual** (excerpt; container address omitted):

```
NCCL INFO NCCL version 2.25.1+cuda12.8
NCCL INFO ncclMaxSharedMem 82240 exceeds device/fn maxSharedMem 79856
NCCL INFO Check P2P Type intraNodeP2pSupport 0 directMode 1
NCCL INFO ncclCommInitAll ... rank 0 nranks 2 ... Init COMPLETE
NCCL INFO Channel 00 : 0[0] -> 1[1] via SHM/direct/direct
NCCL INFO Connected all rings, use ring PXN 0 GDR 1
enqueue.cc:1500 NCCL WARN Cuda failure 1 'invalid argument'
CUDA error: unhandled cuda error
  current device: 1, in function ggml_backend_cuda_comm_allreduce_nccl
```

**Verdict:** shared memory was not the cause; my suspicion was wrong. NCCL
initializes fine and, as expected, uses SHM through host memory (no P2P). It
fails when launching its first allreduce kernel with "invalid argument".
Likely cause (not proven): the bundled NCCL 2.25.1 wants 82,240 bytes of GPU
shared memory per block, but this GPU allows 79,856 (the line just before),
so the kernel launch is rejected. That points to NCCL 2.25.1 not fitting
consumer Blackwell (sm_120) cards.

### 14e. llama.cpp image with a newer NCCL (2026-11-19)

**Why:** decision after 14d: try a newer NCCL instead of dropping tensor
parallelism. Derived image from the exact pinned llama.cpp image (build
12464), only libnccl2 replaced: `scripts/llamacpp-nccl/Dockerfile`. Image
`local/llama.cpp:b12464-nccl`, kept for after the swap.

**Command** (z790, user shell, sudo for Docker; builds a local image, host
unchanged):

```bash
cd ~/benchmarks/2026-11-boardswap
T=local/llama.cpp:b12464-nccl
{
  sudo docker build --progress=plain -t "$T" scripts/llamacpp-nccl
  sudo docker run --rm --entrypoint cat "$T" /nccl-version.txt
  sudo docker image inspect "$T" --format '{{.Id}}'
} 2>&1 | tee before/14e-llamacpp-nccl-build.txt
```

**Expected:** llama.cpp loads libnccl.so.2 as a separate library (package
2.25.1); a newer CUDA 12 build gets installed (version unknown); same path
afterwards.

**Actual:**

```
== before
	libnccl.so.2 => /lib/x86_64-linux-gnu/libnccl.so.2
hi  libnccl2                        2.25.1-1+cuda12.8
== installing libnccl2=2.32.6-1+cuda12.9
Unpacking libnccl2 (2.32.6-1+cuda12.9) over (2.25.1-1+cuda12.8) ...
== after
	libnccl.so.2 => /lib/x86_64-linux-gnu/libnccl.so.2
ii  libnccl2                        2.32.6-1+cuda12.9
sha256:2bef98a2f59e6920b1f00ceb17c443ee02851cc7ff53c164ce10dc4d6b9a0c1b
```

**Verdict:** as expected. NCCL 2.25.1 (held in the image) replaced by 2.32.6;
llama.cpp loads it from the same path, so the swap takes effect.

### 14f. Tensor split with NCCL 2.32.6 (2026-11-19)

**Why:** test the fix from 14e. Same command as 14d, only the image changed.

**Command** (z790, user shell, sudo for Docker; reads only):

```bash
cd ~/benchmarks/2026-11-boardswap
I=local/llama.cpp:b12464-nccl
B=/usr/share/ollama/.ollama/models/blobs
M=/models/sha256-
M=${M}667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29
A=(--rm --gpus all -v "$B":/models:ro --entrypoint /app/llama-bench)
A+=(--shm-size=1g -e NCCL_DEBUG=INFO)
{
  date -u
  sudo docker run "${A[@]}" "$I" -m "$M" -sm tensor -fa on -p 64 -n 16 -r 1
} 2>&1 | tee before/14f-tensor-nccl2.txt
```

**Expected:** NCCL 2.32.6 without the shared memory line; SHM transport; a
working run with tg16 clearly below the ~84 t/s of one card (guess 30-70),
because every layer needs a sync over the bus.

**Actual:**

```
NCCL INFO NCCL version 2.32.6+cuda12.9
NCCL INFO Channel 00 : 0[0] -> 1[1] via SHM/direct
| llama 8B Q4_K - Medium | 4.58 GiB | 8.03 B | CUDA | -1 | tensor | 1 | pp64 | 2639.34 ± 0.00 |
| llama 8B Q4_K - Medium | 4.58 GiB | 8.03 B | CUDA | -1 | tensor | 1 | tg16 |  118.90 ± 0.00 |
```

Two harmless `NCCL WARN` lines (ibverbs wrapper, GDRCopy): network transports
for multi-machine setups, not used here.

**Verdict:** the fix works. My speed prediction was wrong in direction:
tensor split is 41 % faster than one card, not slower. Each card holds half of
every weight matrix and reads only half the model from VRAM per token;
generation is VRAM-bandwidth bound (12b), so two cards can approach 2x. 118.9
t/s is ~71 % of the ideal ~168 t/s; the missing 29 % is sync cost over the bus,
which is what the swap can change (GPU1: x4 behind the chipset -> x8 on the
CPU, about half the latency).

**Consequences for the scripts:**

- `scripts/bench-llamacpp.sh`: all llama.cpp runs use
  `local/llama.cpp:b12464-nccl` (checked by image ID before the run); `row`
  replaced by `tensor`; `--shm-size=1g`; `-fa on` (the documented form;
  `-fa 1` was accepted too).
- `scripts/models.tsv`: new column `engines`; translategemma is `ollama` only.
- Step 14 is re-run completely with the new image. Run 1 (official image) is
  kept in `before/14-run1-official-image/` and
  `results/llamabench-before-run1-official-image.csv` as a repeatability
  check: gpu0, gpu1 and layer do not use NCCL, so they should match.

### Tokens-per-second table (2026-11-19)

At the user's request, every result is collected as tokens per second per
model, scenario and engine, so readers can compare at a glance:

```bash
scripts/make-tps-table.py before
```

writes `results/tps-before.md` (side-by-side table: model x scenario, columns
tg and pp for llama.cpp and Ollama; plus one table per metric) and
`results/tps-before.csv` (long format with standard deviation, token counts,
Ollama load time). Rebuilt after every benchmark run. Tested on a scratch copy
of run 1 data before use.

### 14. llama-bench, single-card models (2026-11-19, run 2, final)

**Why:** the full single-card matrix with the final image
(`local/llama.cpp:b12464-nccl`): GPU0, GPU1, layer and tensor split.
translategemma is skipped (Ollama-only).

**Command** (z790, user shell; the script calls sudo docker, checks the image
ID, reads models read-only; 20 runs, 19:47-19:53 UTC):

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/bench-llamacpp.sh before single
```

Tables (Claude, read-only):

```bash
scripts/make-tps-table.py before
scripts/llamabench-summary.py results/llamabench-before.csv \
  before/14-llamabench > before/14-llamabench-summary.txt
```

**Expected:** gpu0/gpu1/layer within ~2 % of run 1; tensor tg ~30-45 % above
one card, perhaps less for the 14B models; no failures.

**Actual:** 20/20 runs, no failures. Run 2 vs run 1 for gpu0/gpu1/layer (30
values): mean difference 0.11 %, max 1.4 % (the run that was already noisy in
run 1).

Tensor split vs one card (mean of GPU0 and GPU1), t/s:

| Model | tg one card | tg tensor | gain | of ideal 2x | pp one card | pp tensor | change |
|---|---:|---:|---:|---:|---:|---:|---:|
| Llama 3 8B (Q4_0) | 90.2 | 125.0 | +39 % | 69 % | 4293 | 3858 | -10 % |
| Llama 3.1 8B | 84.4 | 118.8 | +41 % | 70 % | 4048 | 3718 | -8 % |
| Qwen3 8B | 79.6 | 110.6 | +39 % | 69 % | 3930 | 3457 | -12 % |
| Qwen2.5 14B | 44.9 | 66.7 | +48 % | 74 % | 2149 | 1990 | -7 % |
| Qwen3 14B | 44.6 | 69.3 | +55 % | 78 % | 2149 | 2163 | +1 % |

Full side-by-side table: `results/tps-before.md`.

**Verdict:** repeatability excellent; the NCCL swap does not affect the other
modes. Tensor gains for 8B as expected, but my guess for 14B was wrong in
direction: the gain is larger (+48/+55 %). The sync cost per layer is roughly
fixed while each card's own work per token grows with model size, so tensor
split pays off more for bigger models. Not predicted: prompt processing gets
slower with tensor split (-7 to -12 %, Qwen3 14B +1 %): with 512 tokens per
step, each sync moves a lot of data over the bus. That is where GPU1's faster
link after the swap should help most.

### 15. llama-bench, large models (2026-11-19)

**Why:** the three models that only fit both cards; layer vs tensor split
decides how fast they run here.

**Command** (z790, user shell; the script calls sudo docker; 6 runs,
19:56-19:59 UTC):

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/bench-llamacpp.sh before dual
```

Tables: `scripts/make-tps-table.py before`; per-run summary in
`before/15-llamabench-summary.txt`.

**Expected:** tg128 27B layer ~24 / tensor ~33-38; 32B layer ~19-21 / tensor
~28-32; 30B-A3B layer ~90-140, tensor uncertain (may fail for qwen35 or
qwen3moe); pp slower with tensor; 8-12 minutes.

**Actual** (t/s, mean of 5, all std. deviations < 0.6 %):

| Model | tg layer | tg tensor | gain | pp layer | pp tensor | change |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3.8 27B (dense) | 24.2 | 37.9 | +56 % | 1103 | 1194 | +8 % |
| Qwen3 32B (dense) | 20.3 | 33.6 | +66 % | 929 | 1111 | +20 % |
| Qwen3 30B-A3B (MoE) | 152.5 | 136.8 | -10 % | 4395 | 3919 | -11 % |

**Verdict:** tensor split works for all three architectures. Dense models as
expected or better (32B tensor 33.6 instead of 28-32, ~83 % of the ideal 2x).
Wrong: the MoE model is faster than predicted with layer split (152.5) and
slower with tensor split (-10 %): only ~3B parameters are active per token, so
each card computes little while the syncs per layer cost the same. Wrong too:
prompt processing gets faster with tensor split for the large dense models.
Across all models the pp change grows with size: -10 % (8B), ~0 % (14B), +8 %
(27B), +20 % (32B). The run took 3 minutes, not 8-12.

### 16a. Ollama image and read-only start (2026-11-19)

**Why:** before ~21 benchmark containers: confirm the image is 0.32.14 (record
the digest), that Ollama starts with the model store mounted read-only and
lists the models, and that the container sees both GPUs.

**Command** (z790, user shell, sudo for Docker; pulls the image, test
container on port 11435, removed at the end; host service untouched):

```bash
cd ~/benchmarks/2026-11-boardswap
IMG=ollama/ollama:0.32.14
M=/usr/share/ollama/.ollama/models
N=bench-ollama-check
A=(-d --name $N --gpus all -e OLLAMA_NOPRUNE=1)
A+=(-v "$M":/root/.ollama/models:ro -p 127.0.0.1:11435:11434)
R='s/GPU-[0-9a-fA-F-]{36}/GPU-<redacted>/g'
{
  sudo docker pull "$IMG"
  sudo docker image inspect "$IMG" --format '{{index .RepoDigests 0}}'
  sudo docker run "${A[@]}" "$IMG"
  sleep 5
  sudo docker exec $N ollama --version
  sudo docker exec $N ollama list
  sudo docker logs $N 2>&1 | sed -E "$R" | tail -20
  sudo docker rm -f $N
} 2>&1 | tee before/16a-ollama-image.txt
```

**Expected:** digest; version 0.32.14; all 13 tags; both GPUs with compute
12.0; no "read-only file system" error.

**Actual** (excerpt):

```
ollama/ollama@sha256:9d30908e41144b1f1da89b9d8e33c07e4aeb43ff41a8660241b1686e2cc330ad
ollama version is 0.32.14
qwen3:32b                             030ee887880f    20 GB     2 hours ago
... (13 tags, IDs identical to the host)
msg="model list cache hydration complete" models=13 failures=0
msg="inference compute" id=1 library=CUDA compute=12.0 name=CUDA1 description="NVIDIA GeForce RTX 5060 Ti" libdirs=ollama,cuda_v13 driver=13.0 pci_id=0000:02:00.0 total="15.5 GiB" available="15.3 GiB"
msg="inference compute" id=0 library=CUDA compute=12.0 name=CUDA0 description="NVIDIA GeForce RTX 5060 Ti" libdirs=ollama,cuda_v13 driver=13.0 pci_id=0000:01:00.0 total="15.5 GiB" available="15.3 GiB"
msg="vram-based default context" total_vram="30.9 GiB" default_num_ctx=32768
```

**Verdict:** as expected; the read-only store works. Not predicted, all
harmless: the container generates a fresh key pair at every start and prints
the public key (not quoted here); Vulkan is enabled by default
(`OLLAMA_VULKAN:true`) but both GPUs are found via CUDA 13; Ollama would pick
a 32K default context from the total VRAM (the client sets 4096); flash
attention is off by default (the benchmark sets it on). No GPU UUIDs in the
log.

### 16b. Ollama benchmark (2026-11-19)

**Why:** the Ollama side of the engine comparison: same models, same cards.
Single-card models (including translategemma) on GPU0, GPU1 and spread; large
models spread only. Fresh container per run; request 0 measures the load.

**Command** (z790, user shell; the script calls sudo docker; models read-only,
host service untouched; 21 runs, 20:09-20:30 UTC):

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/bench-ollama.sh before
```

Tables: `scripts/make-tps-table.py before` -> `results/tps-before.md`.
Server logs (GPU UUIDs redacted): `before/16-ollama/<model>__<config>.log`.

**Expected:** tg gpu0 ~ gpu1 ~ spread; tg 5-15 % below llama.cpp; pp similar
or lower; large models with spread close to llama.cpp layer split (27B ~24,
32B ~20, MoE ~120-150); whole model in VRAM; loads of a few seconds.

**Actual:** 21/21 runs, all models fully in VRAM, all on CUDA. Every model is
served by a bundled llama.cpp `llama-server` (build "1 (7e4c0a968)"), started
with `-c 4096 -np 1 --flash-attn on -b 512 -ub 512 --context-shift`; spread
only makes both GPUs visible (default layer split).

Ollama vs llama.cpp in the same scenario:

- tg: -4.4 % to +1.7 % (8B -2 to -4 %, 14B/32B -1 to -2 %, MoE +1.7 %).
- pp: -3 to -13 % on dense models, -31 % on the MoE (partly method: 543-token
  text prompt vs llama-bench's synthetic 512 tokens).
- Qwen3.8 27B: Ollama enables MTP speculative decoding by itself
  (`--spec-type draft-mtp --spec-draft-n-max 4`; the model has
  `qwen35.nextn_predict_layers = 1`). Draft acceptance 38-68 % per request, so
  tg varies 35-53 t/s; mean 42.8 (+77 % vs llama.cpp layer 24.2, +13 % vs
  llama.cpp tensor 37.9), pp 687 (-38 %). Not like-for-like: llama-bench runs
  without speculative decoding.
- Load times (from page cache, incl. llama-server start): 15-21 s for the
  single-card models, 24-33 s for the large ones.
- Ollama spread vs Ollama one card: tg equal, pp +6 % (llama.cpp layer split
  shows no such gain; unexplained).
- translategemma loads in Ollama's llama-server (124 t/s tg), unlike llama.cpp
  build 12464.

**Verdict:** Ollama's generation speed is much closer to llama.cpp than I
guessed (1-4 % below, not 5-15 %), because it is llama.cpp. Wrong as well: the
27B (speculative decoding, not predicted), the MoE (155 vs 120-150) and the
load times (15-33 s, not a few seconds). Right: equal speed on GPU0, GPU1 and
spread, 32B ~20, everything in VRAM.

### 17. Plan change: llama-server matrix (2026-11-19)

Ollama turned out to run llama.cpp's `llama-server` itself (16b), and for the
27B it enables MTP speculative decoding by itself. Decision (user): combine
the planned llama.cpp load times with a llama-server run that measures
llama.cpp exactly like Ollama, plus MTP on the 27B. Plan grows from 19 to 20
steps (new: an engine conclusion for the Ollama vs llama.cpp decision).

- `scripts/bench-llamaserver.sh before`: same image as steps 14/15 (checked by
  ID), server options as Ollama passes them (`-ngl 99 -c 4096 -np 1 -fa on
  -b 512 -ub 512`), plus `-sm layer|tensor`. Single-card models: gpu0, gpu1,
  layer, tensor; large models: layer, tensor; the 27B additionally layer-mtp
  and tensor-mtp with Ollama's flags (`--spec-type draft-mtp
  --spec-draft-n-max 4 --spec-draft-backend-sampling`). Load time = `docker
  run` until `/health` is ok. 28 runs.
- `scripts/llamaserver-client.py`: same prompt (verified identical, 2718
  characters), same request pattern and generation length as the Ollama
  client; native `/completion` endpoint with `cache_prompt=false`; records
  drafted/accepted tokens with MTP.
- `scripts/make-tps-table.py` now shows three engine columns (llama-bench,
  llama-server, Ollama), MTP scenarios and a load-time table. Ollama's 27B run
  is filed under "layer split + MTP", because its server log shows
  `--spec-type`.

### 17. llama-server matrix (2026-11-19)

**Command** (z790, user shell; the script calls sudo docker; models read-only;
28 runs, 20:40-21:0x UTC):

```bash
cd ~/benchmarks/2026-11-boardswap
scripts/bench-llamaserver.sh before
```

Tables: `scripts/make-tps-table.py before` -> `results/tps-before.md`
(side by side llama-bench / llama-server / Ollama, plus load times).

**Expected:** llama-server tg within ~2 % of llama-bench and ~3 % of Ollama;
pp close to Ollama (±5 %); load 5-15 s; 27B layer-mtp ~ Ollama's 42.8,
tensor-mtp ~55-65 t/s (most uncertain); MTP flags possibly missing in this
build.

**Actual:** 28/28 runs, no failures. The build has `--spec-type ...
draft-mtp ...`, `--spec-draft-n-max`, `--spec-draft-backend-sampling`.

Qwen3.8 27B, generation (t/s):

| Mode | llama-server | Ollama |
|---|---:|---:|
| layer split | 24.2 | - |
| tensor split | 37.8 | - |
| layer split + MTP | 51.8 (45.7-65.2) | 42.8 (35.2-53.2) |
| tensor split + MTP | 73.9 (63.2-93.1) | not available |

MTP draft acceptance (llama-server): 50.7 % (layer), 50.8 % (tensor).

- llama-server vs llama-bench, tg: dense -0.1 to -2.9 %, MoE -5.1 %. pp 1-32 %
  lower (method: 543-token text prompt in 512-token batches = two steps, vs
  llama-bench's single 512-token batch).
- Ollama vs llama-server (identical client and options), dense models without
  MTP: tg -2.1 to +0.5 % (median -0.2 %), pp -1.9 to -6.5 % (median -5.3 %).
  MoE: Ollama tg +7.1 %, pp -24.7 % (Ollama bundles a different llama.cpp
  build, 7e4c0a968).
- Load time (`docker run` until ready): llama-server 2-5 s for 8B/14B, 4-12 s
  for the large models; Ollama 15-21 s and 24-33 s. The first config of each
  model (GPU0) loads slower: the ~95 GB of models do not all fit the 64 GB page
  cache, so the first load partly reads from disk.

**Verdict:** engine parity confirmed: with the same options, Ollama and
llama-server generate at the same speed on dense models. Wrong: load times
even shorter than guessed (2-12 s), and both MTP results higher than guessed;
tensor split + MTP reaches 73.9 t/s on the 27B, 3.1x plain layer split and
1.7x Ollama. Caveat: MTP acceptance depends on the text; the benchmark prompt
is repetitive and probably easier to predict than typical chat, so real gains
may be smaller. The ranking of the modes should hold.

### 18. Summary, before column (2026-11-19)

**Why:** one file with everything measured, before vs after, as the core of
the write-up.

- `scripts/make-summary.py` builds `results/summary.md` from the raw results:
  link under load and idle power (from `<phase>/11-link-samples.csv` and
  `<phase>/04-idle-power.txt`), bus bandwidth and latency
  (`results/nvbandwidth-<phase>.csv`), tokens per second per engine, model and
  scenario, and load times (`results/tps-<phase>.csv`). Columns before, after
  and change; missing "after" data shows as `-`.
- `results/summary-findings.md` holds the hand-written findings and is
  included verbatim. The "before" part is written; "after" is pending.
- Checked: the generated values match the source files; the after path was
  tested on a scratch copy with the before data as fake "after" data (all
  changes +0.0 %), then deleted.

After the swap: `scripts/nvbw-to-csv.py after/10-nvbandwidth.txt >
results/nvbandwidth-after.csv`, `scripts/make-tps-table.py after`, then
`scripts/make-summary.py`.

### 19. Engine recommendation (2026-11-19)

**Why:** answer the user's question (switch from Ollama to llama.cpp to get
the most out of the two cards?) in a form usable for the write-up.

Written into `engines.md`, section "Recommendation (before the swap)": short
answer, a table per use case (best choice, numbers with sources, what was not
measured), what a switch would mean for this homelab, the list of unmeasured
points, and a paragraph for the blog post.

Inputs besides the benchmark: read-only checks of `~/ai-homelab` (roadmap:
Lab 8 plans a LiteLLM gateway with llama-server and vLLM backends; the Ollama
service is hardened in lab 0b) and of `~/ghostwheel` (`.env` not read): it
uses Ollama's native `/api/chat`, `/api/embed` and `/api/tags` (blob check)
behind a backend-agnostic interface, with `qwen3:14b` at 32K context.

Every number was re-checked against `results/tps-before.csv`; comparisons use
Ollama's best mode per model. Two figures were corrected in the process
(Qwen3 14B +55 %, Llama 3.1 8B +41 % against Ollama's one-card result instead
of its spread result; 8B prompt processing with tensor split -8 to -12 %).

### 20. After-swap checklist (2026-11-19)

**Why:** the before numbers cannot be recreated, so the after runs must use
the same images, scripts and order. Written to `AFTER-SWAP.md`:

- A. Before shutting down: record platform settings (step 20a), no
  `apt upgrade`, keep the Docker images.
- B. New board before the first boot: BIOS with 14th-gen support (FlashBack),
  GPUs in the two CPU x16 slots and the manual's lane-sharing table, Secure
  Boot off (the NVIDIA module's MOK is enrolled in the old board's NVRAM),
  same RAM speed / power limits / Resizable BAR as before, EFI fallback.
- C. First boot: both GPUs, network names (Realtek `enp5s0` will be gone),
  fancontrol (old sensor chip and headers), liquidctl (one NZXT USB device
  belongs to the N7 board), services.
- D. Every measurement step with its full command, writing to `after/`, then
  the table scripts.
- E. Expectations to check against.

Found while writing it: RAM speed, XMP, CPU power limits and Resizable BAR
were never recorded, and the new BIOS will start with its own defaults.
Readable without root right now: PL1 = PL2 = 241 W
(`/sys/class/powercap/intel-rapl:0`), governor `powersave`. Step 20a records
the rest (`before/20-platform.txt`); the command is in `AFTER-SWAP.md`.

### 20a. Platform settings before the swap (2026-11-19)

**Why:** the new BIOS starts with its own defaults; host-side bandwidth
depends on RAM speed and power limits. Recorded so the new board can be set
the same and checked.

**Command** (z790, user shell, sudo for dmidecode and Docker; read-only; the
full command is in `AFTER-SWAP.md`, section A) -> `before/20-platform.txt`.

**Expected:** NZXT N7 Z790 BIOS 7.01; 64 GB DDR5 with a configured speed;
PL1 = PL2 = 241 W; governor powersave; microcode 0x133; BAR1 16384 MiB
(Resizable BAR on) or 256 MiB (off); image IDs as recorded earlier.

**Actual:**

```
Manufacturer: NZXT / Product Name: N7 Z790 / BIOS 7.01 (10/13/2023)
2x 32 GB, Part Number CMH64GX5M2D6000Z40, Speed 4800 MT/s,
Configured Memory Speed 6000 MT/s (second slot of each channel)
constraint_0_power_limit_uw:241000000  constraint_1_power_limit_uw:241000000
powersave, microcode 0x133
BAR1 Total 16384 MiB (both GPUs)
local/llama.cpp:b12464-nccl sha256:2bef98a2f59e...
local/nvbandwidth:cuda13.0.0 sha256:fec213b5a3bf...
ollama/ollama:0.32.14 sha256:9d30908e4114...
nvidia/cuda:13.0.0-base-ubuntu24.04 sha256:6e43a6b02e5f...
```

**Verdict:** as expected. XMP is on (6000 MT/s on 4800 MT/s JEDEC modules),
Resizable BAR is on, power limits 241 W. These values are now in
`AFTER-SWAP.md` (section B) as the settings for the new board.

---

## After the swap

### B1-B3. New board: BIOS, GPU slots, Secure Boot (2026-11-22)

**Why:** AFTER-SWAP.md section B, points 1-3: the CPU must be supported, both
GPUs on CPU lanes x8/x8, Secure Boot off (the NVIDIA module's MOK was enrolled
on the old board only).

**Commands** (Claude, read-only, no sudo): `/sys/class/dmi/id/*`,
`/proc/cpuinfo`, each GPU's `current/max_link_*` and its parent port's in
`/sys/bus/pci/devices`, `mokutil --sb-state`, `/proc/driver/nvidia/version`,
`/sys/class/drm/card*`.

**Expected:** a BIOS with 14th-gen support; both GPUs on CPU root ports with
Gen5 x8; Secure Boot disabled; NVIDIA 580.178.04 loaded.

**Actual:**

```
board_name    ROG MAXIMUS Z690 FORMULA
bios_version  4101 (12/03/2024)
model name    Intel(R) Core(TM) i7-14700, microcode 0x133
GPU 0000:01:00.0  port 0000:00:01.0 [8086:a70d]: max 32.0 GT/s x8, device max 32.0 GT/s x8
GPU 0000:02:00.0  port 0000:00:01.1 [8086:a72d]: max 32.0 GT/s x8, device max 32.0 GT/s x8
SecureBoot disabled (Platform is in Setup Mode)
NVIDIA UNIX Open Kernel Module 580.178.04
card3 0000:00:02.0 vendor=0x8086 boot_vga=1 driver=i915; both RTX cards boot_vga=0
uname -r: 7.0.0-43-generic
```

**Verdict:** points 1-3 as expected; no BIOS flash was needed (the board had
run a 14th-gen CPU before). Bus addresses of the GPUs are unchanged; GPU1 now
hangs off the CPU port 00:01.1 instead of the chipset port 00:1b.0.

Three differences to the before state:

- The board is a Z690 **Formula**, not a Hero as planned; all files corrected.
  Irrelevant for the test (two CPU-connected x16 slots, x8/x8).
- The display now runs on the CPU's iGPU (user set onboard VGA as primary in
  the BIOS). Before, GPU0 was the boot VGA with the console framebuffer.
  Expected effect: GPU0's extra ~1.6 W and ~10 MiB at idle disappear; no
  measurable effect on t/s expected.
- Kernel 7.0.0-43 instead of 7.0.0-38: `unattended-upgrades` installed it on
  2026-11-21 21:17 together with glibc 2.39-0ubuntu8.12, perl, tzdata and other
  security updates (`/var/log/apt/history.log`). NVIDIA driver, Docker and the
  container toolkit are unchanged; DKMS rebuilt the same driver for -43.
  My checklist only said "no `apt upgrade`" and missed the automatic updates,
  although `unattended-upgrades` was listed in the baseline. 7.0.0-38 and its
  NVIDIA module are still installed.

**Decisions (user, 2026-11-22):** stay on kernel 7.0.0-43 for the after runs
(documented as a second difference besides the board; the one-card and
layer-split runs serve as controls: if they are unchanged, the kernel had no
measurable effect) and leave `unattended-upgrades` on. Safeguard: before every
measurement step Claude checks read-only that kernel, NVIDIA driver and
`/var/log/apt/history.log` are unchanged since the previous step.

### B4. CPU power limits (2026-11-22)

The new BIOS runs Intel's defaults for the i7-14700: PL1 65 W, PL2 219 W,
PL4 341 W (`/sys/class/powercap/intel-rapl:0`, read-only). Before: PL1 = PL2
= 241 W. Decision (user): stay on the defaults (better for a 24/7 GPU server:
less sustained heat and power; GPU inference keeps the CPU far below 65 W) and
prove it for the comparison: during the after-swap benchmarks the CPU package
power is sampled once per second with `scripts/cpu-power.sh` (RAPL energy
counter, root-only, runs in a second terminal; the benchmark scripts stay
unchanged). If the package never gets near 65 W, PL1 never engages and the
limits cannot affect the results.

### 20a (after). Platform settings after the swap (2026-11-22)

**Command:** as in `AFTER-SWAP.md` section A, writing `after/20-platform.txt`
(user shell, sudo; read-only).

**Expected:** Z690 Formula, BIOS 4101; 2x 32 GB at 6000 MT/s (or 4800 without
XMP); limits 65/219/341 W (decided); BAR1 16384 MiB (or 256 without Resizable
BAR); image IDs identical.

**Actual:**

```
ASUSTeK COMPUTER INC. ROG MAXIMUS Z690 FORMULA, BIOS 4101 (12/03/2024)
2x 32 GB CMH64GX5M2D6000Z40, Configured Memory Speed 6000 MT/s (second slot per controller)
power limits 65000000 / 219000000 / 341000000 uW, governor powersave, microcode 0x133
BAR1 Total 16384 MiB (both GPUs)
image IDs: identical to before/20-platform.txt (diff empty)
```

**Verdict:** as expected: XMP 6000 MT/s and Resizable BAR on, as before;
power limits are the decided Intel defaults; all four images unchanged. Minor:
the new BIOS reports the module "Speed" as 6000 (the old one 4800, the JEDEC
rating); the configured speed is the same.

### C. First boot checks (2026-11-22)

**Commands** (Claude, read-only): `/sys/class/net`, `/etc/netplan` (listing
only, the files are root-only), `journalctl -b -u` for fancontrol,
liquidctl-kraken, ollama and docker, `/sys/class/hwmon`, the unit symlinks in
`/etc/systemd/system/multi-user.target.wants`.

**Expected:** both GPUs visible; `enp5s0` gone and a new Ethernet name; Wi-Fi
name unchanged only if at the same PCI address; fancontrol failing (old sensor
paths); liquidctl possibly failing (one NZXT device was on the N7 board);
services up, no model loaded.

**Actual:**

- GPUs: driver loaded, Ollama's service sees CUDA0 = 01:00.0 and CUDA1 =
  02:00.0 (total VRAM 31.0 GiB, before 30.9: GPU0 no longer holds the console
  framebuffer). No model loaded this boot.
- Network: Wi-Fi is now `wifi0` (Intel, iwlwifi, PCIe 06:00.0
  instead of the CPU's CNVi), up; netplan was changed by the user on
  2026-11-21. Ethernet `enp5s0` exists again, by chance with the same name,
  but now a Marvell AQtion (driver `atlantic`, was Realtek r8169), link down.
- fancontrol: no longer enabled (no symlink, no log this boot);
  `/etc/fancontrol` still points at hwmon2/hwmon6, while the sensor chip
  (still an nct6798) is now hwmon3 and coretemp hwmon7. Fans run on the BIOS
  curves.
- liquidctl-kraken: ran successfully, no errors (Kraken speeds and LCD set).
- Docker 29.8.0 started; SearXNG's bridge and veth are up.
- No package changes since 2026-11-21 21:22; kernel 7.0.0-43, driver
  580.178.04.

**Verdict:** ready for the measurements. Wrong guesses: `enp5s0` was not
"gone" (same name, different chip), Wi-Fi did change name (`wifi0`, set in
netplan by the user), liquidctl did not fail. fancontrol needs a new
`pwmconfig` if wanted; it does not affect the GPU measurements (GPU fans are
controlled by the cards), noted as a difference for temperatures.

### Part 1 after the swap: steps 1, 2, 3, 4, 8 (2026-11-22)

**Why:** the same steps as before the swap, bundled into one script at the
user's request (the sandbox cannot reach the GPUs, Docker or sudo):
`scripts/after-part1.sh`, same commands as journal steps 1-4 and 8, step 2
looks the GPUs and their ports up. Run by the user at 09:03 UTC.

**Expected:** kernel 7.0.0-43, everything else as before; GPU1 at 32GT/s x8
on a CPU root port; topology `PHB`, P2P `CNS`; GPU0 slightly lower at idle (no
console), GPU1 ~9 W; smoke test digest unchanged.

**Actual:**

```
7.0.0-43-generic
0, NVIDIA GeForce RTX 5060 Ti, 00000000:01:00.0, 580.178.04, 98.06.4E.00.8B, 180.00 W, Enabled
1, NVIDIA GeForce RTX 5060 Ti, 00000000:02:00.0, 580.178.04, 98.06.4E.00.8B, 180.00 W, Enabled
ollama 0.32.14, Docker 29.8.0, nvidia-container-toolkit 1.20.2-1

00:01.0 PCI bridge: Intel Corporation Device a70d (rev 01)
		LnkCap:	Port #2, Speed 32GT/s, Width x8, ASPM not supported
01:00.0 VGA compatible controller: NVIDIA Corporation Device 2d04 (rev a1)
		LnkCap:	Port #0, Speed 32GT/s, Width x8 / LnkSta: 2.5GT/s (downgraded), x8
00:01.1 PCI bridge: Intel Corporation Device a72d (rev 01)
		LnkCap:	Port #4, Speed 32GT/s, Width x8, ASPM not supported
02:00.0 VGA compatible controller: NVIDIA Corporation Device 2d04 (rev a1)
		LnkCap:	Port #0, Speed 32GT/s, Width x8 / LnkSta: 2.5GT/s (downgraded), x8

GPU0 <-> GPU1: PHB; P2P read: CNS

idle (60 samples each)   before            after
GPU0                     10.65 W, 12 MiB   9.63 W, 2 MiB, 33-34 °C
GPU1                      9.04 W,  2 MiB   9.78 W, 2 MiB, 31 °C, Gen1 x8 (was x4)

nvidia/cuda@sha256:6e43a6b02e5f... (unchanged), both cards Disp.A Off
```

**Verdict:** as expected, except GPU1's idle power: +0.7 W instead of
unchanged, probably because its link keeps 8 lanes active in the power-saving
state instead of 4 (plausible, not proven). GPU0's drop is 1.0 W, not the
guessed 1.6 W. The CPU port 00:01.0 now advertises x8 instead of x16: the
CPU's 16 lanes are split x8/x8. P2P is still `CNS` with both cards on CPU
lanes, so the driver blocks it for the platform, not because of the old
chipset link.

Pre-check before part 2 (Claude, read-only): `unattended-upgrades` ran again on
2026-11-22 09:02 (just before part 1): it removed old kernels 6.8.0-147 and
7.0.0-34 and updated needrestart, libmysqlclient21, python3-pil, python3-jwt,
git, libnss3, distro-info-data, sosreport, libgstreamer. Nothing in the GPU
path: kernel 7.0.0-43, driver 580.178.04, Docker 29.8.0 and toolkit 1.20.2-1
unchanged; 7.0.0-38 still installed.

### Part 2 after the swap: steps 10, 11, 14-17 with CPU power (2026-11-22)

**Why:** the same measurements as before the swap, bundled into
`scripts/after-part2.sh` (same commands and benchmark scripts; CPU package
power sampled once per second by `scripts/cpu-power.sh`; step start times in
`after/part2-steps.log`). Run by the user, 09:06-09:50 UTC, no failures:
20 + 6 llama-bench runs, 21 Ollama runs (126 requests), 28 llama-server runs
(168 requests).

Analysis (Claude, read-only):

```bash
scripts/nvbw-to-csv.py after/10-nvbandwidth.txt > results/nvbandwidth-after.csv
scripts/link-summary.py after/11-link-samples.csv | tee after/11-link-summary.txt
scripts/llamabench-summary.py results/llamabench-after.csv \
  after/14-llamabench after/15-llamabench > after/14-15-llamabench-summary.txt
scripts/make-tps-table.py after
scripts/make-summary.py
```

#### 10/11. Bus

**Expected:** GPU1 ~17-20 GB/s (before 7.2), latency ~600 ns (before 1191),
no big drop when both GPUs copy at once; both links Gen5 x8 under load.

**Actual** (copy engine, GB/s; all coefficients of variation < 4 %):

| Test | GPU0 before | GPU0 after | GPU1 before | GPU1 after | GPU1 change |
|---|---:|---:|---:|---:|---:|
| host -> GPU | 20.27 | 20.39 | 7.15 | 19.43 | +172 % |
| GPU -> host | 17.29 | 16.83 | 7.26 | 16.62 | +129 % |
| both at once, host -> GPUs | 18.96 | 16.82 | 5.76 | 8.57 | +49 % |
| both at once, GPUs -> host | 16.37 | 15.43 | 5.29 | 8.07 | +53 % |
| host <-> GPU latency (ns) | 612 | 612 | 1191 | 612 | -49 % |
| local VRAM copy | 386 | 386 | 386 | 387 | 0 % |

Link under load: both GPUs Gen5 x8 in all samples (GPU0 162, GPU1 162);
step 11's own run 16.82 / 8.56 GB/s, identical to step 10.

**Verdict:** one GPU at a time as expected: GPU1 now matches GPU0 in
bandwidth and latency. Wrong: with both GPUs copying at once, the total stays
at ~25 GB/s (before 24.7 host -> GPUs, after 25.4), and the split is still
uneven (GPU0 16.8, GPU1 8.6). So the "both at once" limit was not the chipset:
there is a shared limit on the host side of ~25 GB/s for concurrent copies,
and port 00:01.0 gets the larger share. Cause not determined here (CPU I/O
fabric, memory path or how nvbandwidth schedules the copies). GPU0's own
numbers are unchanged, as is local VRAM bandwidth (controls).

#### 14-17. Tokens per second

**Expected:** one card and layer split unchanged within ~1 % (controls, also
for the kernel and power-limit changes); a gain only with tensor split
(+ MTP), guessed 0 to ~+15 %.

**Actual** (change after vs before; full tables in `results/summary.md` and
`results/tps-after.md`):

| Engine, scenario | tg change | pp change | runs |
|---|---:|---:|---:|
| llama-bench, one card (GPU0 / GPU1) | 0.0 to +0.7 % | -1.3 to +1.1 % | 10 |
| llama-bench, layer split | +0.2 to +1.2 % | +0.1 to +0.6 % | 8 |
| llama-server, one card / layer | -0.6 to +0.5 % | -1.0 to +1.3 % | 18 |
| Ollama, one card / spread | -1.0 to +1.0 % | -1.1 to +2.8 % (one +7.5 %) | 19 |
| Ollama / llama-server, layer + MTP (27B) | +0.1 / +0.5 % | +1.9 / +1.5 % | 2 |
| **llama-bench, tensor split** | **+6.7 to +20.9 %** | **+21.8 to +39.2 %** | 8 |
| **llama-server, tensor split** | **+6.7 to +20.4 %** | **+15.9 to +34.6 %** | 8 |
| **llama-server, tensor + MTP (27B)** | **+5.3 %** (73.9 -> 77.8) | **+20.9 %** | 1 |

Tensor split vs one card (or layer split for the large models), llama-bench:

| Model | tg before | tg after | of ideal 2x before -> after | pp before | pp after |
|---|---:|---:|---:|---:|---:|
| Llama 3.1 8B | +40.9 % | +59.4 % | 70 -> 80 % | -8.2 % | +25.7 % |
| Qwen3 14B | +55.4 % | +68.2 % | 78 -> 84 % | +0.7 % | +33.8 % |
| Qwen3.8 27B | +56.4 % | +68.5 % | 78 -> 84 % | +8.2 % | +38.3 % |
| Qwen3 32B | +65.7 % | +76.4 % | 83 -> 88 % | +19.5 % | +49.3 % |
| Qwen3 30B-A3B (MoE) | -10.3 % | +7.2 % | 45 -> 54 % | -10.8 % | +8.3 % |

**Verdict:** controls as expected: every configuration without tensor split
is within about ±1 % (one outlier: Ollama translategemma pp on GPU1 +7.5 %),
so neither the kernel change nor the power limits nor the iGPU display had a
measurable effect. Tensor split gained as expected in direction, more than
guessed at the top (MoE +21 %, 8B models +14 %), and prompt processing gained
much more (+16 to +39 %). The bigger the share of bus time, the bigger the
gain: the small 8B models and the MoE model gain most in generation. Not
predicted: for the MoE model tensor split now beats layer split (+7 %; before
-10 %), and in llama-bench tensor split now speeds up prompt processing for
every model (before it slowed the small models down). Exception in
llama-server: for the MoE model, tensor split generates faster than layer
split (158.2 vs 143.8 t/s) but processes prompts slower (3622 vs 4023).

#### CPU power (new BIOS: PL1 65 W, PL2 219 W)

**Expected:** well below 65 W throughout.

**Actual** (`after/cpu-power.csv`, 2630 one-second samples):

| Step | avg W | p95 W | max W | seconds > 65 W |
|---|---:|---:|---:|---:|
| 10 nvbandwidth | 41.7 | 43.7 | 44.6 | 0 |
| 11 link under load | 40.3 | 42.7 | 42.9 | 0 |
| 14 llama-bench single | 29.3 | 40.0 | 42.7 | 0 |
| 15 llama-bench dual | 32.2 | 40.8 | 44.0 | 0 |
| 16 Ollama | 43.7 | 63.4 | 72.5 | 25 |
| 17 llama-server | 31.9 | 41.5 | 45.3 | 0 |

Highest moving average: 62.3 W over 28 s, 57.6 W over 56 s. Model load times
did not get slower (Ollama median -1.3 %, llama-server -5.8 %).

**Verdict:** mostly as expected; wrong in detail: Ollama's runs exceeded
65 W in 25 single seconds (short spikes, max 72.5 W, during its runs of
loading and serving). PL1 limits the average over a time window (typically
28-56 s on Intel desktop CPUs) and that average never reached 65 W, so PL1
did not engage. The power limits did not affect the results; the controls
confirm it.

### Blog post draft (2026-11-22)

`blog-draft.md`, for gshell.dev (where the homelab posts are published):
TL;DR, setup and the checked differences, method, bus, one card / layer split,
tensor split, MTP, Ollama vs llama.cpp, what went wrong, what was not
measured, conclusion. Every number re-checked against `results/tps-*.csv` and
`results/nvbandwidth-*.csv` (two values updated to the after-swap figures,
one percentage corrected from +9 to +8 %). Scanned for IPs, GPU UUIDs, the
Ubuntu mirror and private names: none.

### Quantization and KV cache type added to the data (2026-11-22)

**Why:** user request: document the models' quantization and the KV cache
type with the results. No re-run needed; both are in the existing data.

**Sources (Claude, read-only):** weight quantization from
`before/05-model-inventory.txt` (GGUF metadata), confirmed by llama-bench's
`model_type` in every result; KV cache type from llama-bench's `type_k` /
`type_v` (104 runs, before and after) and from the Ollama server logs
(`K (f16) ... V (f16)`, 42 logs). llama-server's logs do not print the cache
type at default verbosity; `scripts/bench-llamaserver.sh` sets no
`-ctk/-ctv`, so it ran with the build's default.

**Result:** Q4_K_M for all models except Llama 3 8B (Q4_0); KV cache f16/f16
in every run of every engine. `scripts/make-tps-table.py` now writes `quant`
and `kv_cache` columns into `results/tps-<phase>.csv` and a quant column into
`results/tps-<phase>.md`; `scripts/make-summary.py` adds a "Models and
settings" table; `engines.md` and `blog-draft.md` state both.
