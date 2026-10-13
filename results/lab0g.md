# Lab 0g — Ansible Fundamentals

Date: 2026-10-12 – 2026-10-13 · Managed node: Z790, Ubuntu 24.04.5, kernel 7.0.0-38-generic, Python 3.12.3. Control node: MacBook (Apple M1), macOS 15.7.9, Homebrew Python 3.12.15. ansible-core 2.21.5, ansible-lint 26.9.0. Guide: `docs/guides/lab0g.md` (step numbers below refer to it).

## Goal

Install Ansible reproducibly and learn it on real roles, the way it will be used later: from a separate control node over SSH, with an inventory that holds only host names.

Success criteria (`docs/roadmap.md`), all met:

- From the control node over SSH, `--check --diff` shows the natural drift, a real run fixes it, a second run gives `changed=0`.
- Deliberate drift is detected by check mode and corrected.
- The persistent sysctl from Lab 0a is in a role; the `aa-exec` bypass stays closed and `lab0a-unshare` still works.
- The guide explains every concept used.

## What I did

1. Chose the source and version: pipx + `ansible-core==2.21.5` from PyPI, not apt's 2.16.3; only `ansible-core`, not the `ansible` bundle (step 1).
2. SSH access from the laptop: a `Host z790` entry with user, port, explicit key and `IdentitiesOnly`; verified with `ssh -G` and a `BatchMode` connection (step 2).
3. Installed ansible-core on the laptop with Homebrew `python@3.12` and `pipx install --python` (step 3), and on Z790 with apt's pipx for connection-free checks (step 4); froze both.
4. Cloned the repo on the laptop from Z790 over SSH (step 5).
5. Reviewed `ansible/` and the concepts (steps 6–7).
6. Chose SSH with a names-only inventory over local connection (step 8); added `ansible/ansible.cfg` (inventory path only) and checked it with `ansible-config dump --only-changed`, syntax check and `ansible-inventory` (steps 9–11).
7. First `ping`; pinned `ansible_python_interpreter: /usr/bin/python3` in `inventory/group_vars/all.yml` after a discovery warning (step 12). Tested become over SSH (step 13).
8. Applied `lab_tools`: dry run, real run, functional test, idempotency, deliberate drift (`chmod 0775`), detection, fix (steps 14–20).
9. Moved the Lab 0a sysctl into a new role `common` (file + running value); added `common.yml` and `site.yml`; ran it, forced runtime drift, re-checked the `aa-exec` bypass (steps 21–24).
10. Injected ansible-lint 26.9.0 into the ansible-core venv on both control nodes and ran it; ignored its cache directory `.ansible/` (steps 25–26).

## Measurements

Versions, checked 2026-10-12/13:

| Item | Version |
|---|---|
| apt (noble) `ansible-core` / `ansible` | 2.16.3-0ubuntu2 / 9.2.0+dfsg-0ubuntu5 |
| PyPI `ansible-core` latest | 2.21.5 (2026-10-05), `requires_python >=3.12`, classifiers 3.12–3.14 |
| Target Python minimum (`_PY_MIN` in `module_utils/basic.py`) | 3.9 |
| Z790: Python / pipx | 3.12.3 / 1.4.3 (apt) |
| Laptop: system Python / Homebrew / pipx / uv | 3.9.6 / 7.0.8 / 1.17.13 (depends on `python@3.15`) / 0.12.23 |
| Laptop: Python for Ansible | Homebrew `python@3.12` 3.12.15 |
| PyPI `ansible-lint` | 26.10.1 (2026-10-13), 26.10.0 (2026-10-12), 26.9.0 (2026-09-22, used) |

`pipx runpip ansible-core freeze`, identical on both control nodes (pip on Z790, uv on the laptop):

```
ansible-core==2.21.5
cffi==2.1.1
cryptography==50.0.2
Jinja2==3.1.6
MarkupSafe==3.0.4
packaging==26.3
pycparser==3.11
PyYAML==6.0.3
resolvelib==1.2.1
```

ansible-lint inject: `ansible-lint 26.9.0 using ansible-core:2.21.5 ansible-compat:26.10.0 ruamel-yaml:0.19.1`; 21 added packages (incl. yamllint 1.38.0, black 26.10.1), the nine above unchanged.

Starting state on Z790 (Lab 0a hand-install, 2026-10-11):

- `/usr/local/bin/lab0a-unshare`: identical to `/usr/bin/unshare`, root:root 0755.
- `/etc/apparmor.d/lab0a-unshare`: root:root 0644, 126 bytes; the repo file 124 bytes. Only difference: two spaces before `userns,` on the host.
- `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf`: root:root 0644, 53 bytes, not owned by a package; running value `1`.

Runs (from the laptop unless noted):

| Run | Recap | Notes |
|---|---|---|
| `ping` before pinning the interpreter | SUCCESS | warning; discovered `/usr/bin/python3.12` |
| `ping` after pinning | SUCCESS | no warning, no discovery |
| `command -a id --become` | CHANGED, rc=0 | `uid=0(root)` |
| `lab0a.yml --check --diff` | ok=3 changed=1 skipped=1 | profile diff = indentation; handler skipped |
| `lab0a.yml --diff` | ok=4 changed=2 | profile replaced, handler ran |
| `lab0a.yml --diff` (second) | ok=3 changed=0 | |
| after `chmod 0775`: `--check --diff` | ok=3 changed=1 | binary task, no diff shown for the mode |
| after `chmod 0775`: real run, then again | ok=3 changed=1 → ok=3 changed=0 | ctime new, mtime unchanged |
| `site.yml --limit z790`, check and real | ok=6 changed=0 skipped=1 | `common` adopted the hand-made state |
| after `sysctl -w …=0`: check, real, again | ok=7 changed=1 → ok=7 changed=1 → ok=6 changed=0 skipped=1 | kernel 0 after check, 1 after the real run |
| `ansible-lint` (both control nodes) | Passed: 0 failure(s), 0 warning(s) | 10 of 16 files processed, profile `production` |

Functional checks on Z790 (unprivileged user):

- `lab0a-unshare --user --map-root-user id`: `uid=0(root) gid=0(root) groups=0(root),65534(nogroup)`; with `CapEff`: `000001ffffffffff`.
- `unshare --user --map-root-user id`: `write failed /proc/self/uid_map: Operation not permitted`.
- `aa-exec -p trinity -- unshare --user --map-root-user id -u`: `write failed /proc/self/uid_map: Operation not permitted`.

## What surprised me

- Interpreter discovery does not pick `/usr/bin/python3`: the default list starts at `python3.14` and goes down, so on Ubuntu 24.04 it chose `/usr/bin/python3.12` and warned. Any newer `python3.X` installed later would silently take over.
- A whitespace-only change to the AppArmor profile is `changed` and fires the reload handler, although the compiled policy is identical: Ansible compares text, not meaning.
- `copy` shows no diff when only the mode changes; `changed` without a diff means attributes.
- In check mode `command` reports `skipped` whether it would run or not, unless `creates`/`removes` is set; `removes` was what made runtime drift of the sysctl visible in check mode.
- Homebrew's `pipx` runs on Python 3.15, outside ansible-core 2.21.5's supported 3.12–3.14; the Python for Ansible has to be chosen explicitly. With `uv` installed, pipx used it instead of pip.
- ansible-lint creates its cache in `<repo>/.ansible/` at the project root.

## Mistakes and dead ends

- None.

## Open questions

- The laptop's Ansible venv is tied to Homebrew's `python@3.12`; whether a patch upgrade of that formula breaks it (fix: `pipx reinstall ansible-core`) is still to be seen.

## Follow-ups for later labs

- Lab 1: Molecule tests for `common` and `lab_tools`; ansible-lint in pre-commit/CI; `common` grows with the headless baseline from Prep.
- When more nodes join: add them to the inventory and to the control node's `~/.ssh/config`; drop `--limit z790`.
- After every util-linux upgrade: run `site.yml` so `/usr/local/bin/lab0a-unshare` is refreshed (it does not receive security updates).
- Decide a pinning policy for ansible-core and ansible-lint upgrades (how old a release must be before it is used).

## Step-by-step guide

[docs/guides/lab0g.md](../docs/guides/lab0g.md)
