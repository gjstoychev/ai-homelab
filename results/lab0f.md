# Lab 0f — Claude Code on a Linux Server

Date: 2026-10-14 · Z790, Ubuntu 24.04, kernel 7.0.0-38-generic, AppArmor 4.0.1. Claude Code 2.1.287 (apt, pinned; 2.1.299 native at the start), bubblewrap 0.9.0, socat 1.8.0.0. Guide: `docs/guides/lab0f.md` (step numbers below refer to it).

## Goal

Run Claude Code on Z790 with its built-in Bash sandbox (bubblewrap + socat) enforced by managed settings that the repository cannot loosen, deployed by an Ansible role `claude_code`.

Success criteria (`docs/roadmap.md`), all met:

- A matrix of probes (`touch ~/sandbox-probe` → Read-only file system, `curl --noproxy '*'` → Could not resolve host, reading `~/.ssh`, a disallowed host), all blocked.
- The session refuses to start without the sandbox.
- The configuration is an Ansible role (dependencies, AppArmor profile, managed settings).

## What I did

1. Starting state (step 1).
2. Versions and the update policy: Claude Code moves from the self-updating native installer to Anthropic's signed apt repository, `stable` channel, pinned to `2.1.287-1` and installed by the role (step 2).
3. `/sandbox` before installing anything: only the Dependencies tab; bubblewrap and socat missing, ripgrep and the seccomp filter present (step 3).
4. SSH keys on the node: three deploy keys, one per repository, chosen by `Host` aliases; no account-wide key (step 4).
5. Role decisions: a bwrap copy with its own AppArmor profile selected by managed `bwrapPath`; playbook `claude-code.yml` (`hosts: z790`); Ubuntu packages `present`, `claude-code` pinned with an apt preferences file; the repository key committed to the role (step 5).
6. Role `claude_code`, part 1: bubblewrap, socat, Anthropic's apt repository (key verified by fingerprint), `claude-code=2.1.287-1` with an apt pin; playbook `claude-code.yml` imported by `site.yml` (step 6).
7. Syntax check and ansible-lint on the node and the laptop: clean, profile `production`, 16 of 25 files (step 7).
8. First `--check --diff` from the laptop: `ok=13 changed=5 failed=1 skipped=1`, the expected check-mode failure of the install task on a host without the repository (step 8). Real run: `ok=14 changed=6 failed=0 skipped=1`.
9. Switched the running Claude Code to the package: removed the native install (only binaries in `~/.local/share/claude`; settings and history are in `~/.claude/`), resumed with `claude --continue` on `/usr/bin/claude` 2.1.287 (step 9).
10. bwrap without an exception: `loopback: Failed RTM_NEWADDR: Operation not permitted`; AppArmor moves it into `unprivileged_userns` and denies `setpcap` and `net_admin` (step 10).
11. Role part 2: `/usr/local/bin/claude-bwrap` (copy of `/usr/bin/bwrap`) with AppArmor profile `claude-bwrap` (`userns`); lint clean (16 of 26), check `ok=15 changed=2 skipped=2`, real run `ok=16 changed=3 skipped=1` (step 11).
12. Functional test: `claude-bwrap` works, `/usr/bin/bwrap` stays restricted, `aa-exec` into `trinity` or `claude-bwrap` fails; commands inside `claude-bwrap` inherit its profile and can create a nested user namespace (step 12).
13. Managed settings decided: sandbox enforced (fail closed, no unsandboxed retry, managed-only domains and read paths), manual mode with sandbox auto-allow, secrets denied to both the sandbox and the file tools, four allowed domains (step 13).
14. Role part 3: `/etc/claude-code/managed-settings.json` (root:root 0644); check and real run `ok=17 changed=2 skipped=1`. The running session kept running commands unsandboxed until restart (step 14).
15. Restart: `Setting sources: User settings, Enterprise managed settings (file)`; `/sandbox` refuses to open (overridden by managed settings); commands run under `claude-bwrap` with proxy variables (step 15).
16. Filesystem and process probes: home read-only, `.git/hooks` read-only, repo writable; `CapEff` 0, `NoNewPrivs` 1, seccomp on; a nested user namespace with full capabilities **works** inside the sandbox (step 16).
17. Tested Ubuntu's stacked `bwrap-userns-restrict` model on the copy: incompatible with Claude Code's sandbox (its `apply-seccomp` helper needs `CAP_SYS_ADMIN` in a nested user namespace); not used (step 17).
18. Credential probes: `~/.ssh` empty, `.env` and Claude Code's OAuth token file unreadable, the token variable unset; a `.env` created and read within one command is readable (glob expanded per command) (step 18).
19. Escape hatch: `dangerouslyDisableSandbox` is ignored, the command runs sandboxed; in auto mode the classifier refuses it first; managed settings now set the permission mode. `!` commands run unsandboxed (step 19).
20. Network probes: direct `curl --noproxy` → `Could not resolve host` (only `lo`); a disallowed host → proxy 403 without a prompt; an allowed host → 200 through the proxy (step 20).
21. File tools: Read on `~/.ssh/config` refused by `Read(~/.ssh/**)`; the sandbox does not cover file tools (step 21).
22. From outside: process tree (`claude-bwrap` → socat bridges → `apply-seccomp` from fd 3 → command), namespaces (new net by bwrap; user, mnt, pid by `apply-seccomp`; ipc, uts, cgroup, time shared with the host), bwrap's arguments (`--ro-bind / /`, writable binds, `--tmpfs` for denied directories, `/dev/null` binds for denied files) (step 22).
23. Ollama from the sandbox: direct `localhost:11434` → connection refused (own loopback); through the proxy → 403, not on the allowlist. Decision: no access until the Lab 8 gateway (step 23).
24. `ssh` from the sandbox: `Could not resolve hostname`. Decision: Claude writes, the user runs Ansible (from the laptop) (step 24).
25. GPU: the sandbox's minimal `/dev` has no `nvidia*`; `nvidia-smi` exit 9, `cuInit` 100 (`CUDA_ERROR_NO_DEVICE`). Decision: no GPU in the sandbox; metrics via Prometheus from Lab 2 (step 25).
26. Deliberate drift: bwrap copy not executable → Claude Code refuses to start (`failIfUnavailable`), Ansible restores the mode; AppArmor profile removed → Claude Code starts, commands fail closed, the role did not notice → added a loaded-profile check; check mode `ok=19 changed=1`, real run fixes it (`ok=19 changed=1`), second run `ok=18 changed=0 skipped=2` (step 26).
27. A repository's `.claude/settings.local.json` with `enabled: false`, `excludedCommands`, `allowedDomains` and `allowWrite` changed nothing: still sandboxed, curl sandboxed and refused, home read-only (step 27).
28. Permission allowlist: `Read(//etc/**)`, `Read(//usr/share/**)`, `Read(//sys/**)` and `env.ANSIBLE_LOCAL_TEMP` in the repository's `.claude/settings.json`; no rule for `/proc/<pid>/environ` (the Read tool, outside the sandbox, asks for approval); `git add` and `git commit` pre-approved (step 28).
29. Hooks: `allowManagedHooksOnly` with no managed hooks (a repository cannot bring one); deny rules `Bash(sudo *)`, `Bash(git push *)`; the status line points at the user's own script (step 29).
30. Tests: `git push` refused by the rule; `Read(//etc/**)` works without a prompt; the status line works from managed settings (step 30).
31. CLAUDE.md rules for sessions on the node; headless `claude -p` runs sandboxed commands without prompts (step 31).
32. Commit attribution: default `Co-Authored-By` kept (step 32).
33. Final run: lint clean, `site.yml` idempotent (step 33).

## Measurements

Starting state (2026-10-14):

| Item | Value |
|---|---|
| Claude Code | 2.1.299, native installer (`~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.299`) |
| `bubblewrap` / `socat` | not installed; noble candidates 0.9.0-1ubuntu0.3 / 1.8.0.0-4ubuntu0.1 |
| `kernel.apparmor_restrict_unprivileged_userns` / `_unconfined` | 1 / 1 |
| AppArmor profiles mentioning bwrap in `/etc/apparmor.d/` | none |
| Managed settings (`/etc/claude-code/`) | absent |
| User settings (`~/.claude/settings.json`) | model, status line, theme, `autoMode.environment`; no `sandbox`, no `permissions` |
| Project settings (`<repo>/.claude/`) | absent |

Claude Code versions (npm registry `@anthropic-ai/claude-code`, checked 2026-10-14):

| Item | Value |
|---|---|
| dist-tags | `latest` 2.1.299, `next` 2.1.299, `stable` 2.1.287 |
| 2.1.299 / 2.1.287 / 2.1.285 released | 2026-10-14 / 2026-10-01 / before 2026-09-30 |
| Not in the registry | 2.1.297, 2.1.298 |
| apt repo `stable` (`downloads.claude.ai/claude-code/apt/stable`) | 2.1.277-1, 2.1.280-1, 2.1.285-1, 2.1.286-1, 2.1.287-1 |

Claude Code signing key (`downloads.claude.ai/keys/claude-code.asc`, 2026-10-14): rsa4096, created 2026-03-30, no expiry, fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`, sha256 `bd70a5e4a268002704024ceba7f8446024114e94f3f0bdd11c23a9e592be81c6`.

Installed by the role (2026-10-14):

| Package | Version | Source |
|---|---|---|
| bubblewrap | 0.9.0-1ubuntu0.3 | Ubuntu noble-updates |
| socat | 1.8.0.0-4ubuntu0.1 | Ubuntu noble-updates |
| claude-code | 2.1.287-1 (pinned, priority 1001) | `downloads.claude.ai/claude-code/apt/stable`; one file, `/usr/bin/claude`, 244 MB |

Probe matrix (steps 16–27; all run by Claude in the sandbox unless noted):

| Probe | Result | Layer |
|---|---|---|
| `touch ~/sandbox-probe` | `Read-only file system` | sandbox (filesystem) |
| `touch .git/hooks/sandbox-probe` (inside the repo) | `Read-only file system` | sandbox (protected path) |
| `/proc/self/status` | `CapEff 0`, `NoNewPrivs 1`, `Seccomp 2`, `CapBnd` full | sandbox |
| `unshare --user --map-root-user` | `0`, `CapEff 000001ffffffffff` (**not blocked**) | — (known gap) |
| `ls ~/.ssh`, `wc -c ~/.ssh/config` | 0 entries, `No such file or directory` | sandbox (tmpfs) |
| `~/<project>/.env`, `~/.claude/.credentials.json` | `Permission denied` | sandbox (`/dev/null` bind) |
| `CLAUDE_CODE_MESSAGING_TOKEN` | absent | sandbox (`--unsetenv`) |
| `wc -c < <repo>/work/…/.env` | Bash call refused | permission rules (input redirect) |
| Read tool on `~/.ssh/config`, on a `.env` | refused | permission rules |
| `dangerouslyDisableSandbox: true` | auto mode: refused by the classifier; manual mode: runs sandboxed | classifier / `allowUnsandboxedCommands: false` |
| `!` typed by the user | runs unsandboxed | — (by design) |
| `curl --noproxy '*' https://example.com` | `Could not resolve host`, only `lo` | sandbox (network namespace) |
| `curl https://example.com` | proxy 403, no prompt | sandbox proxy (`strictAllowlist`) |
| `curl https://pypi.org/simple/` | 200 via `::1:3128` | control |
| `curl localhost:11434` / via the proxy | connection refused / 403 | sandbox |
| `ssh -T git@github.com` | `Could not resolve hostname` | sandbox |
| `nvidia-smi`, `cuInit` | exit 9, `CUDA_ERROR_NO_DEVICE` | sandbox (`--dev /dev`) |
| bwrap copy not executable | Claude Code refuses to start | `failIfUnavailable` |
| AppArmor profile removed | starts; commands fail closed | — (role now detects and reloads) |
| Repository `.claude/settings.local.json` loosening four keys | no effect | admin-required sandbox |
| `git push --dry-run` | refused before it runs | permission rule |

Namespaces of a sandboxed command (step 22): new net (bwrap); new user, mnt, pid (`apply-seccomp`, nested); ipc, uts, cgroup, time shared with the host. bwrap arguments: 38 `--ro-bind`, 31 `--setenv`, 4 `--tmpfs`, 4 `--bind`, `--unshare-user`, `--unshare-pid`, `--unshare-net`, `--cap-drop`, no `--disable-userns`.

## What surprised me

The built-in sandbox is solid on files and network (every probe in that part of the matrix was blocked, mostly at the first layer), but on Ubuntu 24.04 it needs an AppArmor exception that its own documentation gets subtly wrong: commands started by bwrap inherit the exception, and Claude Code's seccomp helper relies on capabilities in a nested user namespace, so Ubuntu's own fix for bwrap cannot be applied. The most dangerous moment of the lab was caused by configuration, not by an attack: an AppArmor profile missing from the kernel that neither Claude Code's start-up check nor the first version of the role noticed; it failed closed. Half of the protection lives outside the sandbox (file tools, hooks, the user's own settings file), which is why managed settings and the permission rules matter as much as bwrap. And the agent's own update channel was a surprise: the native installer had moved the session to a release from the same morning.

Details:

- Claude Code's sandbox runtime creates a nested user namespace inside bwrap for its seccomp helper, which it executes from a file descriptor (`comm="3"`), not from a file.
- Commands started inside `claude-bwrap` inherit its AppArmor profile and can create a nested user namespace with root inside, although the documentation says the bwrap profile does not apply to the commands bwrap runs.
- Permission `Read(...)` deny rules are merged into the sandbox, and their globs are expanded at every command; bwrap accepts at most 9000 arguments (about 3000 mounts), so a glob over a large tree such as `/proc` cannot be used.
- On Linux a glob in a sandbox path (`~/**/.env`) is expanded when each command starts: a `.env` that appears while a command runs is readable to it.
- Claude Code's start-up check (`failIfUnavailable`) checks that the bwrap binary exists and is executable, not that a sandbox can be created.
- Managed settings that enforce the sandbox do not set the permission mode: a resumed session kept auto mode.
- Sandbox auto-allow does not cover everything: paths outside the working directory named in file commands, assignments computed at run time, and `dangerouslyDisableSandbox` requests still prompt; `curl` to a URL does not.
- `Read(...)` deny rules also stop Bash commands whose input redirect (`< file`) names a denied path, before the sandbox is involved.
- Denied directories are covered with an empty tmpfs, denied files with a read-only bind of `/dev/null`; `/etc/ssh/ssh_config.d` is hidden too.
- Inside a sandboxed command, `git status` lists the protected-path placeholders (`.bashrc`, `.gitconfig`, `.mcp.json`, `.idea`, …) as untracked files; outside they do not exist.
- The sandbox shares the ipc, uts and cgroup namespaces with the host.
- The sandbox proxy URL carries per-command credentials: the user name is the base64 of the tool call ID.
- Hooks run outside the sandbox with the user's access; without `allowManagedHooksOnly` a cloned repository can bring one. The lock also restricts the status line to managed settings.
- Under an admin-required sandbox a repository cannot add `excludedCommands` or `allowWrite`, but the user's own `~/.claude/settings.json` can.
- Claude's own memory and settings (`~/.claude`) are protected paths: writable only through the file tools.
- A file-based managed policy applies on a Pro account; "not applicable to Pro and Max" in `claude doctor` is about server-managed settings.
- After switching to the package, `claude doctor` still remembers `installMethod: native` and advises `claude install`, which would bring the self-updating build back; `~/.claude.json` had `"autoUpdates": false`, yet the native build had updated itself.
- A sandboxed Ansible fails at start-up (`~/.ansible/tmp` on the read-only home); `ANSIBLE_LOCAL_TEMP` in the sandbox's temp directory fixes it.
- Check mode cannot follow a chain of dependent tasks: the first `--check` on a new host fails at `apt` for a package whose repository the same run would add.

## Mistakes and dead ends

- **Ubuntu's stacked `bwrap-userns-restrict` model** (step 17): would deny capabilities to everything bwrap runs, but Claude Code's `apply-seccomp` helper needs `CAP_SYS_ADMIN` in its own nested user namespace and has no path on disk (`comm="3"`), so no sandboxed command can start under it. Not used. Known upstream (checked 2026-10-14): anthropics/claude-code#87680 (on Ubuntu 26.04, where the profile is enabled by default, the sandbox does not start); anthropics/sandbox-runtime#428 (open; fixes proposed in the runtime). The workaround in circulation, `priority=1 capability sys_admin,` in `/etc/apparmor.d/local/unpriv_bwrap`, re-opens the gap for every bwrap user.

## Is the control worth it?

The configuration around the sandbox is not a separate layer: it is Claude Code's built-in sandbox, plus what Ubuntu 24.04 requires for it to start (bubblewrap, socat, an AppArmor exception), plus a root-owned place for its options (managed settings) and a role to repeat it. The nested user namespace gap is in the built-in sandbox itself; the documented `/usr/bin/bwrap` profile has it too, host-wide. It cannot be closed from outside: there is no single command (`unshare(CLONE_NEWUSER)` is a system call any program can make, so `Bash(unshare *)` is only a speed bump), AppArmor cannot target the pathless `apply-seccomp`, and the seccomp rule that would close it belongs in Claude Code's own helper (sandbox-runtime#428). Until then the defence is a patched kernel (54 pending updates on the node, `apparmor` among them).

## Open questions

- Are the deploy keys read-only or read/write? (GitHub → repository → Settings → Deploy keys.) A read/write key that leaks allows pushes to that repository, including `main` without branch protection.
- Does the per-command expansion of `~/**/.env` cost noticeable start-up time as the home directory grows?

## Follow-ups for later labs

- Lab 1: security-update policy (54 pending updates during the lab, `apparmor` among them; the bwrap copy needs the role after every bubblewrap upgrade).
- Lab 2: put Prometheus (GPU exporter) on the sandbox allowlist so Claude can read GPU state over HTTP instead of device access.
- Lab 8: how sandboxed commands reach inference: the gateway's host:port in managed `allowedDomains` with a narrow virtual key, not Ollama's bare API.
- Lab 11: sandboxed commands can create a nested user namespace with full capabilities; add it to the red-team list and close it in variants A (Landlock + seccomp) and B (gVisor). When sandbox-runtime#428 / claude-code#87680 are fixed, repeat the probe (step 16) and retry the stacked profile (step 17).
- `lab_tools`: a removed `lab0a-unshare` profile is not detected; add the loaded-profile check if the role stays.

## Step-by-step guide

[docs/guides/lab0f.md](../docs/guides/lab0f.md)
