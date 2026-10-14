# ai-homelab

A two-node AI infrastructure home lab covering hardware, Linux fundamentals, inference serving, observability, and infrastructure as code with Ansible.

Write-ups of these labs are published at https://gshell.dev.

Lab order, scope and status: `docs/roadmap.md`. Lab results live in `results/`; reusable commands live in `docs/runbook.md`.

## Nodes

- `z790` — GPU compute node: i7-14700, 64 GB DDR5, 2x RTX 5060 Ti 16 GB
- `b760` — control node: i5-14400F, 32 GB DDR5, no GPU (currently powered off)

One RTX 5060 Ti will later move to `b760` to compare single-node multi-GPU (scale-up) with multi-node, one GPU per node (scale-out). Full component list and GPU topology: `docs/hardware.md`.

## Labs

- Lab 0a — Container from Scratch: `results/lab0a.md`. Write-up: [A container in 81 lines of Bash](https://gshell.dev/blog/container-from-scratch/)
- Lab 0g — Ansible Fundamentals: `results/lab0g.md`. Write-up: [From manual tweaks to Ansible roles](https://gshell.dev/blog/ansible-first-steps/)
- Lab 0f — Claude Code on a Linux Server: `results/lab0f.md`
- Lab 0b — systemd as a Platform
- Lab 0c — iptables → nftables
- Lab 0d — Python for Infrastructure
- Lab 0e — Nagios → Prometheus
- Lab 1 — Hardware Audit and IaC Baseline
- Lab 2 — Observability
- Lab 3 — Benchmark Methodology
- Lab 4 — Quantization Shootout
- Lab 5 — KV Cache in Practice
- Lab 6 — TP vs PP vs DP on 2× RTX 5060 Ti
- Lab 7 — Fitting Beyond VRAM
- Lab 8 — AI Gateway
- Lab T3 — Ghostwheel as the First Tenant
- Lab 9 — RAG for Ghostwheel
- Lab 10 — k3s + GPU Operator
- Lab T1 — MCP Servers in TypeScript
- Lab 11 — Hardened Sandbox for Claude Code
- Lab 12 — Firecracker for Untrusted Code
- Lab 13 — Supply Chain and Runtime Detection
- Lab 14 — QLoRA and Multi-LoRA Serving
- Lab 15 — Disaster Recovery Game Day
- Lab T2 — GPU Fleet Control Panel
- Lab 16 — Capstone: Claude Code as a Junior SRE
