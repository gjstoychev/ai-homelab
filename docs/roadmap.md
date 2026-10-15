# Lab Roadmap

Version 1.5 · 2026-10-14. This file is the source of truth for lab order, scope and status. Hardware: `docs/hardware.md`. Per-lab outcomes: `results/<lab>.md`; procedures: `docs/guides/<lab>.md`.

Progress: mark `[x]` in a lab's heading when it is complete.

## Rules for every lab

A lab is complete only when it has:

1. **Code in git:** an Ansible role, Helm chart, script or configuration.
2. **A measurement:** a Grafana dashboard or a table in `results/<lab>.md`.
3. **A note:** "what surprised me" (3–5 sentences).
4. **A guide:** `docs/guides/<lab>.md`, the step-by-step procedure with commands and the reasoning; useful commands also go into `docs/runbook.md`.
5. **Mistakes and dead ends:** recorded, not deleted. If the lab is interesting to others: a blog post skeleton for gshell.dev.

## Schedule (~24 weeks, part-time)

| Weeks | Phase | Focus |
|---|---|---|
| 1–3 | **0 — Modernization** | Container from scratch, Ansible, Claude Code sandbox, systemd, nftables, Python, Prometheus |
| 4–5 | **A — Foundation** | Hardware audit + IaC baseline, observability, benchmark methodology |
| 6–11 | **B — Fitting & multi-GPU** | Theory, quantization, KV cache, TP/PP/DP, offload, RPC |
| 12–15 | **C — Gateway & platform** | Gateway + Ghostwheel, RAG, k3s, MCP servers in TypeScript |
| 16–19 | **D — Security** | Sandbox for Claude Code, Firecracker, supply chain |
| 20–24 | **E — Final** | QLoRA, DR game day, control panel, capstone |

Labs are listed in execution order; the numbering is an identifier, not the order.

## Preparation (before Phase 0)

### [x] Prep — Headless servers (Z790)

- **Status (Z790, 2026-10-07):** the server turned out to be practically headless already (no display manager, 2 MiB VRAM per card), so the iGPU step was dropped as unnecessary. The real finding: `nvidia-persistenced` was running with `--no-persistence-mode`; fixed with a drop-in; `multi-user.target`; verified on a cold start. Results: `results/prep-headless.md`. B760 is pending.
- **Why before the labs:** every Lab 1 baseline (VRAM, idle power, thermals, power limit) must be measured without Xorg/gnome-shell on GPU0; it also frees VRAM for Ghostwheel right away.
- **Z790:** in the BIOS, primary display → iGPU (UHD 770 on the i7-14700); check that the iGPU is not disabled when a discrete card is present. Console and firmware go to the motherboard's HDMI; both 5060 Ti cards stay fully for compute.
- **B760:** the 14400F has no iGPU, so the 1070 stays the console card; headless means only no display manager.
- On both: `systemctl set-default multi-user.target`, display manager masked, `nvidia-persistenced` active (without X nobody keeps the driver initialized → slower first CUDA call, skewed TTFT).
- **Measure before and after** in `results/prep-headless.md`: `display_active`, VRAM used, idle power, P-state, graphics processes per card.
- **IaC:** by hand now; codified in the `common` and `nvidia_*` roles in Lab 1 (the role checks and enforces the same state).
- **Claude Code until Lab 0f:** standard manual mode only (every command approved), no auto mode and no `bypassPermissions`.

## Phase 0 — Modernization (weeks 1–3)

### [x] Lab 0a — Container from scratch

- A "container" in ~100 lines of Bash: `unshare` (pid, mount, net, uts, user), cgroups v2 by hand through `/sys/fs/cgroup`, `pivot_root`, `ip netns` + veth.
- **Criterion:** a process inside sees only itself as PID 1, has a memory limit and networking through veth.
- **Why:** afterwards Podman, gVisor and Kubernetes stop being magic. The script is also variant A in Lab 11.
- **Status (2026-10-07 – 10-11):** all 6 criteria met; `scripts/minicontainer.sh` (81 lines), `results/lab0a.md`, `docs/guides/lab0a.md`, runbook; blog post on gshell.dev. The role `ansible/roles/lab_tools` was written but not applied; installing Ansible, applying the role and moving the persistent sysctl into a role moved to Lab 0g.
- **Deviations from the plan:** compared with Docker (already installed), not Podman; NAT to the internet deferred to Lab 0c; user namespace through a dedicated `lab0a-unshare` copy with its own AppArmor profile (not globally); `kernel.apparmor_restrict_unprivileged_unconfined = 1` enabled on the host (closes the Qualys `aa-exec` bypass).
- **Key findings:** 124 ms vs 518 ms (Docker) start-up; the `dmem` controller is empty for NVIDIA 580, so VRAM cannot be limited through cgroups; Docker also creates a time namespace; root in the container (and in default Docker) is root on the host.

### [x] Lab 0g — Ansible fundamentals

- **Status (2026-10-12 – 10-13):** all criteria met; control node = laptop over SSH, `ansible/site.yml` (roles `common` and `lab_tools`), ansible-lint clean at profile `production`. `results/lab0g.md`, `docs/guides/lab0g.md`, runbook.
- **Why:** every later configuration change becomes an Ansible role, and Lab 0f's `claude_code` role needs a working Ansible that is understood, not copied. Ansible gets its own lab with a full tutorial instead of being a tail of Lab 0a.
- **Bootstrap (cannot be a role):** pipx from apt + `ansible-core==2.21.5` from PyPI. Checked 2026-10-12: apt ships ansible-core 2.16.3 and ansible 9.2.0; the latest on PyPI is 2.21.5 and requires Python >= 3.12; the host has 3.12.3. Only `ansible-core`, not the `ansible` bundle: the roles use only `ansible.builtin`. The exact dependency versions (`pipx runpip ansible-core freeze`) go into results.
- **Concepts (tutorial in the guide):** desired state vs scripts, idempotency, agentless execution (control node vs managed node, interpreter discovery), inventory, playbooks, roles and their directory layout, modules and FQCNs, handlers and `notify`, facts, check mode and `--diff` and their limits.
- **Control node and connection:** the laptop (macOS) is the control node and reaches z790 over SSH; the inventory holds only host names, connection details live in the control node's `~/.ssh/config`. Ansible also stays on z790 for connection-free checks (syntax, inventory, config, lint). `ansible-config dump --only-changed`.
- **First workload, `lab_tools` from Lab 0a:**
  - `--check --diff` shows the natural drift: the hand-written AppArmor profile differs from the repo in the indentation before `userns,`. The repo is the source of truth; Ansible enforces it.
  - A real run fixes the profile and reloads it; a second run gives `changed=0`.
  - Deliberate drift (the mode of `/usr/local/bin/lab0a-unshare`) is detected by `--check --diff` and corrected.
- **Persistent sysctl:** `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf` (applied by hand in Lab 0a) moves into a separate role, `common` (decided in the lab), byte-for-byte equal to the file on the host, and applied immediately, not only written. Afterwards the `aa-exec` bypass fails and `lab0a-unshare` still works.
- Explicit `mode` on every file that runs or is read as root (git does not keep group-write).
- **Decided in the lab:** ansible-lint 26.9.0 now; `site.yml` as the entry point now (imports `common.yml` and `lab0a.yml`). Molecule belongs to Lab 1.
- **Criterion:** from the laptop over SSH, `--check --diff` shows the natural drift → a real run fixes it → a second run gives `changed=0`; deliberate drift is detected and corrected; the sysctl is in a role; the guide explains every concept used.

### [x] Lab 0f — Claude Code on a Linux server

- **Status (2026-10-14):** all criteria met. Role `claude_code` in `site.yml`: Claude Code 2.1.287 from Anthropic's apt repository (pinned), bubblewrap + socat, a bwrap copy with its own AppArmor profile (loaded state checked), managed settings (sandbox enforced and fail-closed, admin-required, manual mode, secrets denied to commands and file tools, four allowed domains), `allowManagedHooksOnly` with no managed hooks. `results/lab0f.md`, `docs/guides/lab0f.md`, runbook, `CLAUDE.md`.
- **Deviations from the plan:** Claude Code itself moved from the self-updating native installer to the apt package (pinned in the role); a permission allowlist step was added; no custom PreToolUse hook (declarative deny rules and `allowManagedHooksOnly` instead; transcripts serve as the audit trail); the probe matrix also covers GPU, Ollama, SSH and the repository's own settings.
- **Key findings:** commands inside bwrap inherit its AppArmor exception and can create a nested user namespace with full capabilities; Ubuntu's stacked `bwrap-userns-restrict` fix breaks Claude Code's sandbox (its `apply-seccomp` helper needs `CAP_SYS_ADMIN` in a nested namespace; anthropics/sandbox-runtime#428, claude-code#87680) → Lab 11. `failIfUnavailable` checks the bwrap binary, not a working sandbox. Hooks and file tools run outside the sandbox. The sandbox shares ipc/uts/cgroup with the host.
- **Decided in the lab:** no Ollama (until the Lab 8 gateway), no SSH/Ansible runs, no GPU from the sandbox (metrics via Prometheus in Lab 2); the SSH keys on the node are per-repository deploy keys.
- The built-in sandbox: `bubblewrap` + `socat`, an AppArmor profile for `bwrap` only (Ubuntu 24.04 restricts unprivileged user namespaces). With `lsns` during a session, recognize the namespaces from Lab 0a.
- Modes (auto-allow / regular), `strictAllowlist`, `allowUnsandboxedCommands: false`, `failIfUnavailable: true` (otherwise commands run unsandboxed when a dependency is missing).
- `sandbox.credentials` deny for `~/.ssh`, `.env` and tokens: by default the sandbox can read almost the whole machine.
- Settings hierarchy: user / project / managed; what the repo cannot loosen.
- What stays outside the sandbox: file tools, MCP servers, hooks; covered by permission rules.
- **Architecture decisions (recorded):** sandboxed commands cannot reach the host's `localhost` (Ollama on :11434); non-HTTP tools (`ssh`, therefore Ansible) do not go through the proxy. "Claude writes, I run" vs `excludedCommands` + an ask rule.
- Test: do `nvidia-smi` and CUDA work inside bwrap.
- Hooks (PreToolUse guard + audit log), `CLAUDE.md`, headless `claude -p`.
- **Criterion:** a matrix of probes (`touch ~/sandbox-probe` → Read-only file system, `curl --noproxy '*'` → Could not resolve host, reading `~/.ssh`, a disallowed host), all blocked; the session refuses to start without the sandbox.
- **IaC:** a `claude_code` role (dependencies, AppArmor profile, managed settings), so B760 is just `ansible-playbook`. Prerequisite: Lab 0g.
- Check the SSH key in `~/.ssh`: a deploy key for ai-homelab only, or a personal key for the whole GitHub account. The setting for the Co-Authored-By line in commits.
- Check that `bwrap` works with `apparmor_restrict_unprivileged_unconfined = 1` enabled.

### [ ] Lab 0b — systemd as a platform (in progress)

- **Status (2026-10-15):** started. Scope change: the second service is a small demo service created for the lab (own unit, secrets in an `EnvironmentFile`).
- Ollama and a demo service as systemd services: `MemoryMax`, `CPUQuota`, `Restart=on-failure`, `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`.
- `systemd-analyze security <unit>`: raise the score.
- Ad-hoc limits: `systemd-run --scope -p MemoryMax=2G <cmd>`.

### [ ] Lab 0c — iptables → nftables

- Translate old rules with `iptables-translate`, then rewrite by hand with nftables sets.
- **Criterion:** default-deny egress for a specific UID with an allowlist. Foundation for Lab 11.
- From Lab 0a: NAT from the lab namespace to the internet; how ufw, Docker's rules (`FORWARD DROP`) and nftables underneath coexist.
- The ufw rules for Ollama (11434) are tied to Docker bridge names `br-<id>` and break silently when a network is recreated. Pin Docker network names and subnets in IaC; clean up stale rules.

### [ ] Lab 0d — Python for infrastructure

- `uv`, type hints, `asyncio`, `httpx`.
- **A mock OpenAI-compatible server (FastAPI)** with simulated latency and streaming, for gateway tests and load testing without a GPU.
- An async load generator measuring TTFT and ITL; compare with `vllm bench serve`.
- Read `vllm/entrypoints/openai/` and trace one request to the scheduler.

### [ ] Lab 0e — Nagios → Prometheus

- Pull vs push, labels, PromQL, alerts on **symptoms** (SLOs), not causes.
- Translate 3–4 Nagios checks into Prometheus alert rules and argue the difference.

## Phase A — Foundation and measurement (weeks 4–5)

### [ ] Lab 1 — Hardware audit and IaC baseline

- Ansible inventory; roles: `common`, `nvidia_open` (Z790), `nvidia_legacy_580` (B760 / 1070), `container_runtime`, `tuning`.
- The two driver roles are mutually exclusive: this is a deliberate lab on driver lifecycle.
- Network: a direct 2.5GbE point-to-point link (/30, no gateway or DNS) + WiFi for management; `iperf3` baseline on both paths.
- Thermals under 30+ minutes of continuous load: temperatures, clocks and throttle reasons separately; power limit 150 W vs 180 W. The upper card (GPU0) is worse off: it draws in the lower card's exhaust and has ~1 cm of clearance above it.
- Measure: PCIe `LnkCap` vs `LnkSta`, `nvidia-smi topo -m`, P2P (`p2pBandwidthLatencyTest`), host↔device bandwidth.
- Tuning: persistence mode; power limit 180 W vs 140 W (tok/s per watt); CPU governor; pinning to P-cores.
- The `common` and `nvidia_*` roles codify the headless state from Prep (default target, masked display manager, `nvidia-persistenced` drop-in).
- From Prep / Lab 0a: HWE kernel (7.0): pin the kernel or only the driver, and a security update policy; an own modprobe file `zz-homelab-nvidia.conf` (not `99-`) and removal of the hand-made `nvidia-kms.conf`; a oneshot unit for the power limit at boot (`-pl` does not survive a reboot); explicit `mode: "0755"` for scripts run as root (git does not keep group-write).
- Test: GPU0 draws ~0.7 W more than GPU1 at idle: PCIe 5.0 x8 vs 4.0 x4, boot VGA or silicon (`nvidia-smi -q -d PCIE` at idle).
- Network: management is now over LAN (not WiFi); Z790 has one wired port, so the direct link to B760 needs a second NIC or a switch. netplan in Ansible with the passwords in Vault.
- **Molecule** tests for the roles.
- **Criterion:** `ansible-playbook site.yml` on a clean Ubuntu 24.04 → working GPUs in a container.

### [ ] Lab 2 — Observability

- Control plane on **B760** (containers next to the 1070): Prometheus, Grafana, Loki; node_exporter on both nodes; a GPU exporter on Z790 (compare DCGM exporter and nvidia_gpu_exporter for consumer cards).
- Scrape vLLM `/metrics` and llama-server `--metrics`.
- **Criterion:** a dashboard with TTFT, tokens/s, KV cache %, GPU util/power/temp, queue depth.

### [ ] Lab 3 — Benchmark methodology

- One model (~8B), three engines: Ollama, llama-server, vLLM; one dataset (ShareGPT or real Ghostwheel requests).
- Concurrency 1 / 4 / 16 / 64 → TTFT, TPOT, throughput; latency vs throughput curve.
- **Expected lesson:** Ollama/llama.cpp win at single-user, vLLM at concurrency.

## Phase B — Fitting and multi-GPU (weeks 6–11)

### [ ] Theory week (before Lab 4)

- Why decode is memory-bandwidth-bound; the roofline model; parameters × bits = VRAM.
- Course: DeepLearning.AI *Efficiently Serving LLMs*.

### [ ] Lab 4 — Quantization shootout

- A ~14–32B model: GGUF Q4_K_M / Q5_K_M / Q8_0 (with and without imatrix), AWQ, GPTQ, FP8, **NVFP4**, EXL3.
- Measure: VRAM, tok/s, perplexity / KL-divergence against FP16, 2–3 tasks from lm-eval-harness.
- **Result:** an own table "bits per weight ↔ quality ↔ speed".

### [ ] Lab 5 — KV cache in practice

- Compute the KV size by hand (`bytes/token = 2 × layers × kv_heads × head_dim × bytes_per_element`; Llama-3.1-8B in FP16: 128 KiB/token, ≈4 GiB at 32k context) and compare with the vLLM log ("GPU KV cache size: N tokens").
- Experiments: `--kv-cache-dtype fp8`, `--gpu-memory-utilization`, `--max-model-len`, prefix caching with a long shared system prompt (hit rate).

### [ ] Lab 6 — TP vs PP vs DP on 2× 5060 Ti

> The last lab that needs both cards together (with Lab 7). Afterwards GPU1 moves to B760.
> **Known asymmetry: GPU0 Gen5 x8, GPU1 Gen4 x4.** Hypothesis to test: with this topology DP beats TP more clearly than with symmetric x8/x8. Also the most publishable result of the whole plan.

- A model that fits on one card: DP (2 replicas + HAProxy) vs TP=2.
- A model that does not fit (~30B AWQ): TP=2 vs PP=2.
- `NCCL_DEBUG=INFO`: which transport is used.
- **Baseline for Phase C:** record throughput and TTFT of the two replicas on one machine. After GPU1 moves to B760, the same test on two nodes answers whether one machine with two cards beats two nodes with one each: two replicas on one machine share CPU, RAM and the PCIe complex; two nodes do not.
- **Expected lesson:** without P2P, TP mainly buys memory, not speed. Document the break-even point.

### [ ] Lab 7 — Fitting beyond VRAM

- 70B Q4 with llama.cpp: partial `-ngl`, `--tensor-split`, threads on P-cores.
- A large MoE: experts in RAM (`--n-cpu-moe` / `-ot`), attention in VRAM. Measure what really fits in 64 GB of RAM.
- **llama.cpp RPC:** `rpc-server` on B760 (1070 + RAM); layers over the network. Compare WiFi vs direct 2.5GbE vs (later) 25GbE. The network as the bottleneck is the main lesson here.

## Phase C — Gateway and platform (weeks 12–15)

### [ ] Lab 8 — AI gateway

- Architecture: `Traefik (TLS, edge) → LiteLLM (routing, keys, budgets, fallback) → HAProxy (L4 health checks) → vLLM / llama-server / Claude API`.
- Scenarios: fallback to the Claude API on 429/timeout; a virtual key with a budget; rate limits per key; sticky routing by prefix hash (prefix cache locality).
- **Chaos:** `kill -9` on a replica during a load test: how many requests are lost? Tune `retries` / `redispatch`.

### [ ] Lab T3 — Ghostwheel as the first tenant

- Ghostwheel moves from direct Ollama to the LiteLLM gateway: virtual key, budget, Langfuse traces.
- **Why:** a real workload and real performance data instead of synthetic ones.

### [ ] Lab 9 — RAG for Ghostwheel

- Qdrant + embeddings and reranker on **B760** (the 1070 is fully sufficient for TEI / llama-server `--embedding`), so they do not interfere with inference on Z790.
- Ingestion pipeline, hybrid search (dense + sparse), reranking, Langfuse traces for every step.
- **Eval set:** 50 hand-written questions → recall@k. Also used in Lab 14.

### [ ] Lab 10 — k3s + GPU Operator (2 weeks)

- k3s with **two** nodes: server on B760, agent on Z790. **No HA control plane:** etcd quorum needs 3 nodes, which is theory for a homelab.
- GPU Operator or device plugin; labels `gpu=blackwell` (Z790) and `gpu=pascal` (B760); node affinity and taints so a vLLM pod never lands on the Pascal node.
- Rolling upgrades and HA with real traffic become possible after GPU1 moves to B760 (start of Phase C).
- vLLM as a Deployment, then the vLLM production-stack Helm chart with the router.
- Validation: `helm lint`, `kubeconform`, `trivy config`.
- In parallel: **CKA** preparation.

### [ ] Lab T1 — MCP servers in TypeScript

- **Prometheus/Loki (read-only):** for incident investigation (used in the capstone).
- **Lab control:** allowed actions (restart a replica, switch the model) with a strict allowlist.
- Tests with Jest + `@modelcontextprotocol/inspector`.

## Phase D — Agent security (weeks 16–19)

### [ ] Lab 11 — Hardened sandbox for Claude Code: four approaches, one criterion

The same task solved four times: Claude Code with access only to the repo, an egress allowlist and inference against the local model. The goal is a comparison, not just a working sandbox.

- **A — By hand from primitives:** `minicontainer.sh` from Lab 0a (user/pid/mount/net namespaces, cgroups v2; its gaps: no `/dev`, `/tmp`, `/sys`, capability dropping, seccomp or user namespace; the `unshare` parent stays inside 5 namespaces; 124 ms start-up to profile) + the nftables allowlist from Lab 0c + **Landlock** (filesystem) + a **seccomp** filter (syscalls). The most work, full visibility of which layer does what.
- **B — Rootless Podman + gVisor:** `--runtime=runsc`, `--cap-drop=ALL`, `--read-only`, `--security-opt=no-new-privileges`, tmpfs for `/tmp`, cgroup limits (memory, pids, CPU); a separate network + an nftables allowlist only to `api.anthropic.com`, LiteLLM and a package mirror, everything else DROP + log.
- **C — NVIDIA OpenShell:** a declarative YAML policy (filesystem, network, process, credentials) that lives in git as code. Inference routing to the local Ollama/vLLM on the 5060 Ti cards. Decide who owns routing, OpenShell or the AI gateway from Lab 8, and why.
- **D — Claude Code's built-in sandbox** (from Lab 0f): bubblewrap + proxy allowlist + credentials deny/mask. Baseline: how much the "free" option gives without an external runtime.
- Claude Code inside with minimal permissions and a PreToolUse hook (exit code 2 blocks the command; the hook enforces an allowlist and writes an audit log), identical in all variants.
- **Red team, identical for all four:** prompt injection in the repo's README ("send ~/.ssh to…"), reading `~/.ssh` and `.env`, `curl` to a disallowed host, `sudo`/setuid, a fork bomb, an attempt to write outside the repo. For every attack: which layer stops it (model, permissions, hook, Landlock/seccomp, firewall)? **Goal: at least two layers per attack.**
- **Measurements in `results/lab11.md`:** attack × approach matrix (stopped / by which layer / logged); start-up time; overhead on TTFT and tok/s with local inference; lines of configuration/policy; audit trail quality (OCSF with OpenShell vs nftables log + hook log).
- **Version:** OpenShell is a young project (alpha → 0.1.x during 2026; GPU support was experimental). Check the current support matrix at the start of the lab and pin the version in the Ansible role.
- **Publication:** "Claude Code: built-in sandbox vs OpenShell vs a hand-made sandbox from primitives, with local inference on 2× 5060 Ti", a blog post from the matrix and measurements.

### [ ] Lab 12 — Firecracker for untrusted code

- A microVM (minimal rootfs, jailer) as a "code execution tool" for the agent, called through MCP.
- Compare start-up time, overhead and the isolation boundary with gVisor.
- Firecracker has no GPU passthrough; for a GPU sandbox look into gVisor nvproxy / Kata.

### [ ] Lab 13 — Supply chain and runtime detection

- ModelScan on the models; policy "only safetensors/GGUF, pinned by commit hash".
- Trivy for images; cosign sign/verify.
- Tetragon or Falco: alert on `execve` of a shell in an inference container.

## Phase E — Final (weeks 20–24)

### [ ] Lab 14 — QLoRA and multi-LoRA serving

- Unsloth QLoRA on one 5060 Ti (the other stays for serving).
- Base model + 2–3 LoRA adapters in vLLM (`--enable-lora`), routed through LiteLLM by model name.
- **Eval gate:** an adapter is deployed only if it passes the eval set from Lab 9.

### [ ] Lab 15 — Disaster recovery game day

- restic to an external disk on Z790 + offsite (B2 / Hetzner Storage Box): configs, Qdrant snapshots, LoRA, eval results, dashboards.
- Base weights are not backed up, only a manifest with hashes and URLs (512 GB disks).
- **Game day:** reinstall **B760** and time the full recovery from git + restic only. A better test than a spare machine, because the node has a real role (control plane, observability, Qdrant).
- With two nodes, 3-2-1 requires at least one medium outside both.

### [ ] Lab T2 — GPU fleet control panel (React/TS)

- A dashboard reading Prometheus and the LiteLLM API: loaded models, KV cache, queues, budgets per key.
- Actions go through the MCP server from Lab T1.
- **Why:** a portfolio piece showing the rare infra + frontend combination.

### [ ] Lab 16 — Capstone: Claude Code as a "junior SRE"

- MCP (read-only) over Prometheus/Loki → Claude Code investigates an alert.
- Headless `claude -p` in GitHub Actions: on an alert/issue the agent analyzes and **opens a PR**; Argo CD applies after a manual approve. Never direct access to production.
- `CLAUDE.md` with architecture, SLOs, forbidden actions, testing and rollback.
- **Criterion:** an injected incident (e.g. `--gpu-memory-utilization` too low → growing queue) → the right diagnosis and a PR with evidence from the metrics.
