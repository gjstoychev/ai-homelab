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
