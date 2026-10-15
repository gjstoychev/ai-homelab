# Lab 0f — Claude Code on a Linux Server: Step-by-Step Guide

Status: complete. Last updated: 2026-10-14. Results on this hardware: `results/lab0f.md`.

## Overview

Claude Code runs on Z790. Its built-in sandbox wraps every shell command Claude runs in bubblewrap (filesystem, PID, network namespaces) and routes network traffic through a proxy with a domain allowlist. This lab installs the sandbox's dependencies, gives `bwrap` an AppArmor exception for user namespaces (Ubuntu 24.04 restricts them), enforces the sandbox with managed settings that a repository cannot loosen, and proves it with a matrix of probes. Everything is deployed by an Ansible role, `claude_code`.

Documentation used: code.claude.com/docs/en/sandboxing, /settings, /settings-reference, /managed-settings (read 2026-10-14).

## Working conventions

- Same as Lab 0g: each step says where a command runs (node or control node), whether it needs root and whether it changes anything. Ansible runs from `<repo>/ansible` on the control node, always `--check --diff` first.
- Changes to settings and the sandbox need a Claude Code restart; `claude --continue` resumes the same conversation.
- Placeholders: `<repo>` is the checkout path, `<user>` the account on the node.

---

# Part 1 — Starting state and versions

## Step 1/33 — Starting state

**Why:** know the Claude Code version and install method, whether the sandbox's dependencies exist, how AppArmor is configured, and which settings already apply in each scope (managed, user, project) before changing anything. Several sandbox behaviours tested later need Claude Code v2.1.285 or later.

**Command** (node, read-only, no root):

```bash
claude --version; command -v claude; readlink -f "$(command -v claude)"
command -v bwrap socat; apt-cache policy bubblewrap socat | grep -E '^[a-z]|Installed|Candidate'
sysctl kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined
grep -rl bwrap /etc/apparmor.d/
ls -la /etc/claude-code; ls -la ~/.claude/settings*.json; ls -la <repo>/.claude
```

**Result (2026-10-14):**

- Claude Code 2.1.299, native installer: `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.299` (the native installer updates itself; see step 2).
- `bwrap` and `socat` are not installed; noble candidates `bubblewrap 0.9.0-1ubuntu0.3`, `socat 1.8.0.0-4ubuntu0.1`. Without them the sandbox cannot start at all.
- Both AppArmor sysctls are `1` (the userns restriction, and the `common` role's restriction on unconfined profiles).
- No file in `/etc/apparmor.d/` mentions bwrap: Ubuntu 24.04 ships no profile for it, so ours cannot conflict with a distribution profile.
- No managed settings (`/etc/claude-code/` absent), no project settings (`<repo>/.claude/` absent). User settings have no `sandbox` or `permissions` keys.

## Step 2/33 — Versions and how Claude Code is updated

**Why:** versions are pinned in this repo, preferably to a release that is a few weeks old. The native installer updates itself on every start and periodically in the background (`latest` channel by default), so the version running today is not a decision anyone made.

**Command** (node, read-only):

```bash
curl -fsS https://registry.npmjs.org/@anthropic-ai/claude-code | python3 -I -c 'import json,sys; d=json.load(sys.stdin); t=d["time"]; print("dist-tags:", d["dist-tags"]); [print(v, t[v][:10]) for v in sorted((v for v in t if v[0].isdigit()), key=lambda v: t[v])[-12:]]'
curl -fsS https://downloads.claude.ai/claude-code/apt/stable/dists/stable/main/binary-amd64/Packages | grep -E '^(Package|Version|Filename):'
```

The npm registry is the public list of releases (the native installer and the npm package share version numbers). The second command reads the index of Anthropic's apt repository, `stable` channel.

**Result (2026-10-14):** `latest` = 2.1.299, released that day; `stable` = 2.1.287 (2026-10-01). The apt repository keeps older versions (2.1.277-1 … 2.1.287-1), so an exact version can be pinned.

**Options considered** (update settings from code.claude.com/docs/en/setup):

| Option | How | For | Against |
|---|---|---|---|
| A | Native installer on `latest` (default) | Nothing to do | Not pinned; the version changes without a decision |
| B | Native installer, `autoUpdatesChannel: "stable"` | Releases about a week old, regressions skipped | Still changes weekly; install stays manual, outside Ansible |
| C | Native installer, exact version, `DISABLE_UPDATES=1` | Truly pinned | Install stays manual, in `$HOME` |
| **D (chosen)** | Anthropic's signed apt repository (`stable`), exact version `2.1.287-1`, installed by the `claude_code` role | Pinned; in Ansible, so a new node is one playbook run; signed packages; root-owned `/usr/bin/claude` | A third-party repository on the host; larger scope than the sandbox alone |

`DISABLE_AUTOUPDATER` stops only the background check (`claude update`/`claude install` still work); `DISABLE_UPDATES` blocks every update path. Package manager installations never update themselves. Regardless of the option, managed settings will set `requiredMinimumVersion: "2.1.285"`: from that version on, repository settings cannot loosen an admin-required sandbox.

## Step 3/33 — Concepts, and the `/sandbox` panel before anything is installed

**Why:** the sandbox is one of several layers that decide what Claude can do. Knowing which layer covers what explains every probe later in the lab. The `/sandbox` panel is where Claude Code itself reports missing dependencies and the resolved configuration.

**Concepts** (code.claude.com/docs/en/sandboxing, 2026-10-14):

- **What it wraps.** The sandbox applies to the commands Claude runs through the Bash tool (also PowerShell and Monitor) and to every process they start. It is off by default (`sandbox.enabled`).
- **Two independent layers.**
  - *Filesystem* (bubblewrap on Linux): writes only to the working directory, a per-user temp directory (`$TMPDIR` is set to it) and added directories; reads to **almost the whole machine by default, including `~/.ssh`**, unless denied.
  - *Network*: the command runs in its own network namespace with no route out. Traffic goes through a proxy that Claude Code runs outside the sandbox (reached through `socat`), selected with `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`. The proxy checks each hostname against the allowed domains, which start empty. Tools that ignore the proxy variables (plain `ssh`, most database drivers) and anything that is not TCP (UDP, QUIC, ICMP) cannot leave.
  - Both layers are needed: without the network layer a compromised command can exfiltrate what it reads; without the filesystem layer it can rewrite files that later run with more access.
- **Protected paths.** Even inside writable directories the sandbox denies writes to files Claude Code loads configuration or code from: `.claude/` settings, skills, agents, commands and hooks, `.mcp.json`, `.git/hooks` and `.git/config`, shell startup files in the working directory, most of `~/.claude`. Otherwise a command could grant itself permissions or plant a hook that runs outside the sandbox. No setting exempts them.
- **What runs outside the sandbox:** Claude's file tools (Read, Edit, Write) and web tools (WebFetch, WebSearch), hooks, MCP servers, the status line command; commands typed by the user at the `!` prompt; commands matching `sandbox.excludedCommands`; and an *unsandboxed retry* (`dangerouslyDisableSandbox`) unless `allowUnsandboxedCommands` is `false`. File tools are governed by **permission rules** (`Read(...)`, `Edit(...)` deny/allow), not by sandbox paths.
- **Sandbox vs permission rules vs permission modes.** Permission rules decide whether a tool call runs, evaluated on the command text before it runs. Permission modes (manual, acceptEdits, auto, plan, dontAsk, bypassPermissions) decide who approves. The sandbox is enforced by the kernel on the running process, whatever the command text claims to do. Sandbox *auto-allow* mode runs sandboxed commands without a prompt because the boundary contains them; it is not the same as *auto mode*, where a classifier reviews actions.
- **Settings hierarchy**, highest first: managed (`/etc/claude-code/managed-settings.json` and `managed-settings.d/*.json` on Linux), command line (`--settings`), project local (`.claude/settings.local.json`), shared project (`.claude/settings.json`), user (`~/.claude/settings.json`). Scalars: the higher level wins. Arrays (paths, domains, rules) are merged across levels. Some keys are honoured only from user, managed or `--settings` (e.g. `sandbox.network.strictAllowlist`, `sandbox.filesystem.disabled`), and some only from managed (e.g. `sandbox.bwrapPath`).
- **Admin-required sandbox.** When managed settings set `sandbox.allowUnsandboxedCommands: false` (or `sandbox.network.allowManagedDomainsOnly: true`), Claude Code ignores the settings in a repository's `.claude/` files that would loosen the sandbox: `excludedCommands`, `allowedDomains`, `allowWrite`, `Edit(...)` allow rules as write grants, `true` for the weakening switches, and `false` for `enabled`/`failIfUnavailable`. Requires v2.1.285+. A cloned repository therefore cannot switch the sandbox off or widen it.
- **Fail closed.** By default, if the sandbox cannot start (missing dependency), commands run **unsandboxed**. `sandbox.failIfUnavailable: true` makes Claude Code refuse to start instead.

**Command** (in a Claude Code session on the node; changes nothing; do not select anything, choices are saved to `.claude/settings.local.json`):

```
/sandbox
```

**Expected:** with a required dependency missing, the panel shows only the *Dependencies* tab.

**Result:**

```
Sandbox  Dependencies

ripgrep (rg): found

bubblewrap (bwrap): not installed
  · apt install bubblewrap

socat: not installed
  · apt install socat

seccomp filter: installed
```

The optional seccomp filter (blocks Unix domain sockets) is present: it ships with the native Claude Code binary, so `@anthropic-ai/sandbox-runtime` from npm is not needed. To re-check with the apt package in step 14.

## Step 4/33 — Which SSH keys are on the node, and what they unlock

**Why:** by default the sandbox can read `~/.ssh`. How much a leaked key is worth depends on what it unlocks: a deploy key opens one repository, a personal key every repository of the account. That decides how strictly `~/.ssh` is denied (step 12).

**Command** (node, no root, changes nothing; private keys are not read):

```bash
ls -la ~/.ssh; for f in ~/.ssh/*.pub; do ssh-keygen -lf "$f"; done; git -C <repo> remote -v
for h in $(awk '/^Host /{print $2}' ~/.ssh/config) github.com; do echo "== $h"; ssh -T -o BatchMode=yes git@$h; done
```

The second line connects to GitHub with each `Host` alias of `~/.ssh/config`, then with `github.com` itself (default key). GitHub names what the key unlocks: `Hi <owner>/<repo>!` for a deploy key, `Hi <owner>!` for a personal key. Exit code 1 is normal (no shell access).

**Result:** three ed25519 keys (private `0600`, public `0644`), each a **deploy key for one repository**, selected per repository by a `Host` alias in `~/.ssh/config` (the remote is `git@github-ai-homelab:<owner>/ai-homelab.git`); the default key belongs to a third repository. There is no key for the whole account on the node.

Consequence for the design: sandboxed commands never need `~/.ssh` (pushes are run by the user, outside the sandbox), so the whole directory is denied to them, and to the file tools with a `Read` deny rule.

---

# Part 2 — The `claude_code` role: packages and the AppArmor exception

## Step 5/33 — Design decisions for the role

**Why:** settle where the user-namespace exception lives, how the playbook is named, how versions are pinned and where the repository key comes from, before writing any task.

**5a. The AppArmor exception for bwrap.** With `kernel.apparmor_restrict_unprivileged_userns = 1`, bwrap needs a profile that grants `userns`.

| Option | For | Against |
|---|---|---|
| (a) Profile for `/usr/bin/bwrap` (the documented way) | bwrap stays a package file and gets apt updates | Every program and script that runs the system `bwrap` gets a user namespace with full capabilities; could collide with a profile Ubuntu ships later |
| **(b) chosen:** a copy `/usr/local/bin/claude-bwrap` with its own profile, selected by managed `sandbox.bwrapPath` | Narrow and explicit (the Lab 0a model); `/usr/bin/bwrap` stays restricted; `bwrapPath` is honoured only from managed settings, so a repository cannot redirect it | The copy gets no apt updates by itself; the role refreshes it on every run (`copy` with `remote_src`, by checksum), so run the role after bubblewrap upgrades. World-executable, like `lab0a-unshare` |
| (c) `kernel.apparmor_restrict_unprivileged_userns = 0` | Nothing to write | Removes the protection for the whole host. Rejected |

**5b. Playbook:** `claude-code.yml` with `hosts: z790`, imported from `site.yml`. Named after what it installs, not after the lab: unlike `lab_tools`, this is permanent configuration. Not every host needs Claude Code, so not `hosts: all`.

**5c. Version pinning:**

- `bubblewrap`, `socat`: `state: present`, versions recorded in results. They come from Ubuntu and must keep receiving security updates; an exact pin would make the role downgrade them.
- `claude-code`: exact version `2.1.287-1` in the `apt` task, plus an apt pin file `/etc/apt/preferences.d/claude-code` (`Pin-Priority: 1001`), so a manual `apt upgrade` does not silently move it. A `dpkg` hold would also work but is invisible in `/etc` and gets in the way of a planned upgrade through the role.

**5d. Repository signing key:** committed to the role (`files/claude-code.asc`) after checking its fingerprint against the documentation; reviewed once, versioned in git, no network dependency for the key on each run.

## Step 6/33 — The role, part 1: packages and the Claude Code apt repository

**Why:** install what the sandbox needs and Claude Code itself from a pinned, signed source. The AppArmor exception comes later (step 10), so that step 9 can show what happens without it.

**Verify the signing key before it enters the repo** (node, no root; writes only to a scratch directory, not to `~/.gnupg`):

```bash
d=$(mktemp -d); curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$d/claude-code.asc"
gpg --homedir "$d" --show-keys --with-fingerprint "$d/claude-code.asc"; sha256sum "$d/claude-code.asc"
```

**Expected / Result (2026-10-14):** `rsa4096 2026-03-30 [SCE]`, fingerprint `31DD DE24 DDFA B679 F42D  7BD2 BAA9 29FF 1A7E CACE` (as published in code.claude.com/docs/en/setup), uid `Anthropic Claude Code Release Signing <security@anthropic.com>`, no expiry; sha256 `bd70a5e4a268002704024ceba7f8446024114e94f3f0bdd11c23a9e592be81c6`. The file becomes `roles/claude_code/files/claude-code.asc`.

**Files** (all in the repo):

- `roles/claude_code/tasks/main.yml`: `apt` bubblewrap + socat (`present`); `/etc/apt/keyrings` (`0755`); the key and `/etc/apt/sources.list.d/claude-code.sources` (`copy`, `0644`, both `notify: Refresh the apt cache`); `/etc/apt/preferences.d/claude-code` (`template`, `0644`); `meta: flush_handlers`; `apt` `claude-code={{ claude_code_version }}`.
- `roles/claude_code/files/claude-code.sources` (deb822 format):

  ```
  Types: deb
  URIs: https://downloads.claude.ai/claude-code/apt/stable
  Suites: stable
  Components: main
  Signed-By: /etc/apt/keyrings/claude-code.asc
  ```

- `roles/claude_code/templates/claude-code.pref.j2`: `Package: claude-code`, `Pin: version {{ claude_code_version }}`, `Pin-Priority: 1001` (above 1000: apt keeps, and if needed downgrades to, exactly this version).
- `roles/claude_code/defaults/main.yml`: `claude_code_version: "2.1.287-1"`.
- `roles/claude_code/README.md`: what the role does, how to upgrade Claude Code, how to replace the signing key.
- `claude-code.yml` (`hosts: z790`, `become: true`, role `claude_code`), imported at the end of `site.yml`.

Notes:

- A plain `copy` of a `.sources` file instead of `ansible.builtin.deb822_repository`: that module needs `python3-debian` on the node; `copy` needs nothing and installs the file byte for byte.
- **`meta: flush_handlers`.** Handlers normally run at the end of the play; the cache refresh must happen before `apt` installs `claude-code`, or the first run cannot find the package. `flush_handlers` runs the notified handlers at that point.
- A handler instead of `when: <register>.changed`: ansible-lint's `no-handler` rule flags the latter.

## Step 7/33 — Connection-free checks on both control points

**Why:** catch YAML, module and structure errors before anything connects to the node. The control node sees only committed history, so the role is committed on the node first and pulled on the laptop (Lab 0g convention).

**Command** (node in `<repo>/ansible`, then the laptop after `git pull --ff-only`; read-only):

```bash
ansible-playbook site.yml --syntax-check
ansible-lint
```

**Expected / Result:** `playbook: site.yml` on both; `Passed: 0 failure(s), 0 warning(s) in 16 files processed of 25 encountered. Last profile that met the validation criteria was 'production'.` on both (Lab 0g: 10 of 16). ansible-lint announces 26.10.1; the pin on 26.9.0 stays.

## Step 8/33 — First run from the control node

**Why:** see what the role would change before it changes anything, then apply it.

**Command** (control node, from `ansible/`; root on the node through become):

```bash
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Expected (check mode):** `common` and `lab_tools` unchanged (`ok`, one `skipping`), as at the end of Lab 0g. In `claude_code`: the dependencies `changed`; `/etc/apt/keyrings` `ok` (it exists on Ubuntu 22.04 and later); the key, the `.sources` file and the pin file `changed`, each with a diff from `(absent)`; the handler `Refresh the apt cache` runs (counted as `ok` and `changed`, but nothing is refreshed); then:

```
TASK [claude_code : Install Claude Code]
fatal: [z790]: FAILED! => {"changed": false, "msg": "No package matching 'claude-code' is available"}

PLAY RECAP
z790 : ok=13 changed=5 unreachable=0 failed=1 skipped=1 rescued=0 ignored=0
```

**Why the first check on a new host ends with `failed=1`.** In check mode the key and repository tasks only *report* that they would write their files, and the cache refresh does not run, so apt has never heard of `claude-code` when the install task asks for it. Check mode cannot follow a chain of tasks where a later one depends on what an earlier one would have changed. This is expected on every host where the repository does not exist yet, and only there: after the first real run, check mode works, including for upgrades (the new version is already in the cache, the install task shows `changed`). Two ways to make the task "pass" in check mode were rejected: `ignore_errors: "{{ ansible_check_mode }}"` would also hide real errors (a mistyped version during an upgrade), and `when: not ansible_check_mode` would hide every upgrade from check mode. The role's README says the same.

**Result (real run):** the same diffs; the handler refreshes the cache (`changed`); apt installs `claude-code` as the only new package. Recap `ok=14 changed=6 unreachable=0 failed=0 skipped=1`.

**Verify on the node** (read-only):

```bash
dpkg-query -W bubblewrap socat claude-code; apt-cache policy claude-code | head -8
ls -l /etc/apt/sources.list.d/ /usr/bin/claude; dpkg -L claude-code
```

**Result:** `bubblewrap 0.9.0-1ubuntu0.3`, `socat 1.8.0.0-4ubuntu0.1`, `claude-code 2.1.287-1`. The pin holds: `*** 2.1.287-1 1001` is both installed and candidate, older versions are at 500. The package is a single 244 MB binary, `/usr/bin/claude` (root:root `0755`), plus its copyright file; it adds no apt source, cron job or systemd unit of its own.

A native installation (`~/.local/bin/claude`) still comes first in `PATH`; step 9 removes it.

## Step 9/33 — Switch the running Claude Code to the apt package

**Why:** a native installation in `~/.local/bin` comes first in `PATH` and shadows `/usr/bin/claude`, and it keeps updating itself. After the switch the binary is root-owned, pinned and managed by the role.

**Look before deleting** (node, read-only):

```bash
ls -la ~/.local/share/claude ~/.local/share/claude/versions; ls -l ~/.local/bin/claude; du -sh ~/.local/share/claude
```

**Result:** `~/.local/share/claude` holds only `versions/`, three complete Claude Code binaries (2.1.292, 2.1.296, 2.1.299; 739 MB together), and `~/.local/bin/claude` is a symlink to the newest. Nothing else is there: no settings, no conversation history, no memory, no credentials. All of that lives in `~/.claude/` (and `~/.claude.json`), which the switch does not touch, so conversations survive and `claude --continue` resumes them with the new binary. The file dates also show the auto-updater at work: 2.1.299 had installed itself on the morning of the lab.

> **Before deleting `~/.local/share/claude`, know what it is.** It contains only native-installer binaries (old versions are kept for running sessions and rollbacks). Settings, history, projects, memory and artifacts are in `~/.claude/` — never delete that directory as part of this switch.

**Command** (node, no root; deletes only in your own home). Exit the running session first (`/exit`):

```bash
rm -f ~/.local/bin/claude && rm -rf ~/.local/share/claude && hash -r && command -v claude && claude --version
claude doctor
cd <repo> && claude --continue
```

`hash -r` makes the shell forget the cached location of `claude`. Deleting the binary of a running process is safe on a local disk (the process keeps the open inode), but exiting first keeps it simple.

**Expected:** `/usr/bin/claude`, `2.1.287 (Claude Code)`; `claude doctor` recognises a package installation without auto-updates.

**Result:**

```
/usr/bin/claude
2.1.287 (Claude Code)
```

`claude doctor` (trimmed):

```
Running: package-manager (2.1.287)
Package manager: deb
Path: /usr/bin/claude
Config install method: native
Auto-updates: Managed by package manager
Last update attempt: success → 2.1.299 (2026-10-14)

1 warning found
- claude command at ~/.local/bin/claude missing or broken
  Fix: Run claude install to repair the installation.
```

> **Do not follow that fix.** Claude Code remembers the old install method in `~/.claude.json` (`"installMethod": "native"`), so `claude doctor` reads the deleted launcher as a broken installation. `claude install` would put the self-updating native build back into `~/.local/bin`, ahead of `/usr/bin/claude` in `PATH`. The warning is expected after the switch. Managed settings (step 13) set `DISABLE_UPDATES=1`, which makes `claude install` and `claude update` refuse. Editing `~/.claude.json` by hand was rejected: it is undocumented internal state.

The other lines are leftovers of the native period (`Last update attempt`, `Auto-update channel: latest`) and do not affect the package. `~/.claude.json` also holds `"autoUpdates": false`, yet the native build had updated itself that morning; to stop updates, use the documented `DISABLE_AUTOUPDATER` / `DISABLE_UPDATES`.

## Step 10/33 — bwrap without the exception

**Why:** see the problem the AppArmor profile solves. On Ubuntu 24.04 an unprivileged process may create a user namespace, but AppArmor moves it into the `unprivileged_userns` profile, which denies capabilities inside it. bwrap needs them to set up mounts and the network (the same restriction `unshare` hit in Lab 0a).

**Command** (node; the first without root, the second with root; nothing changes):

```bash
bwrap --ro-bind / / --unshare-all --die-with-parent id; echo "exit=$?"
sudo dmesg | grep -i apparmor | tail -5
```

`--ro-bind / /` gives the whole root read-only, `--unshare-all` asks for every namespace (user, pid, net, ipc, uts, cgroup), `id` is the command inside.

**Result:**

```
bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
exit=1
```

```
apparmor="AUDIT" operation="userns_create" class="namespace" info="Userns create - transitioning profile" profile="unconfined" pid=18997 comm="bwrap" requested="userns_create" target="unprivileged_userns" execpath="/usr/bin/bwrap"
apparmor="DENIED" operation="capable" class="cap" profile="unprivileged_userns" pid=18998 comm="bwrap" capability=8  capname="setpcap"
apparmor="DENIED" operation="capable" class="cap" profile="unprivileged_userns" pid=18998 comm="bwrap" capability=12  capname="net_admin"
```

How to read it:

- The user namespace **is** created and the uid map written (otherwise the error would be about the uid map). The `AUDIT` line shows the transition from `unconfined` to `unprivileged_userns` at creation.
- bwrap then brings up loopback in the new network namespace (`RTM_NEWADDR`, a netlink request to add 127.0.0.1 to `lo`), which needs `CAP_NET_ADMIN` inside the namespace: denied, fatal. The sandbox needs that loopback: commands reach Claude Code's proxy through a local port inside the namespace.
- `setpcap` is denied too (bwrap drops capabilities from the bounding set for the command it runs); that one is not fatal.
- The capability checks happen in the child (pid 18998) that bwrap creates inside the new namespaces.

## Step 11/33 — The role, part 2: a bwrap copy with its own AppArmor profile

**Why:** give user namespaces to one dedicated binary only, the one managed settings will point Claude Code at (step 5a), and leave `/usr/bin/bwrap` restricted.

**Files:**

- `roles/claude_code/files/claude-bwrap`:

  ```
  abi <abi/4.0>,
  include <tunables/global>

  profile claude-bwrap /usr/local/bin/claude-bwrap flags=(unconfined) {
    userns,
  }
  ```

  The profile attaches by path to the copy; `flags=(unconfined)` means it restricts nothing else, and `userns,` lets the binary create user namespaces with capabilities inside them.
- `roles/claude_code/tasks/main.yml`: `copy` with `remote_src: true` from the node's own `/usr/bin/bwrap` to `/usr/local/bin/claude-bwrap` (root:root `0755`); `copy` of the profile to `/etc/apparmor.d/claude-bwrap` (`0644`) with `notify: Reload claude-bwrap AppArmor profile`.
- `roles/claude_code/handlers/main.yml`: `apparmor_parser -r /etc/apparmor.d/claude-bwrap` (`changed_when: true`). Writing the file alone changes nothing until the kernel loads it.
- `roles/claude_code/README.md`: why a copy, and the caveat that the copy gets no bubblewrap security updates by itself; run the role after each bubblewrap upgrade.

**Command** (node in `<repo>/ansible`, then the laptop after `git pull --ff-only`; then the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Expected / Result:**

- Lint: `Passed: 0 failure(s), 0 warning(s) in 16 files processed of 26 encountered` (the profile is encountered but not linted).
- Check mode: everything from part 1 `ok` (this time the install task does not fail: the repository and the package exist); the bwrap copy `changed` (no diff is printed for a new binary file); the profile `changed` with a diff from `(absent)`; the reload handler `skipping` (a `command` in check mode). Recap `ok=15 changed=2 skipped=2`.
- Real run: the same, and `RUNNING HANDLER [claude_code : Reload claude-bwrap AppArmor profile]` `changed`. Recap `ok=16 changed=3 skipped=1 failed=0`.

## Step 12/33 — Functional test of the exception

**Why:** Ansible reports state; the point is the effect. The copy must work, the system bwrap must stay restricted, the new unconfined profile must not open the `aa-exec` bypass, and we want to know what the commands *inside* bwrap inherit.

**Command** (node, unprivileged user, no root; nothing changes):

```bash
claude-bwrap --ro-bind / / --unshare-all --die-with-parent id; echo "exit=$?"
bwrap --ro-bind / / --unshare-all --die-with-parent id; echo "exit=$?"
aa-exec -p trinity -- unshare --user --map-root-user id -u
aa-exec -p claude-bwrap -- unshare --user --map-root-user id -u
claude-bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all --die-with-parent sh -c 'cat /proc/self/attr/current; echo; unshare --user --map-root-user id -u'
```

**Result:**

```
uid=1000(<user>) gid=1000(<user>) groups=1000(<user>),65534(nogroup)     # claude-bwrap: works
bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted             # /usr/bin/bwrap: still restricted
unshare: write failed /proc/self/uid_map: Operation not permitted         # aa-exec into trinity
unshare: write failed /proc/self/uid_map: Operation not permitted         # aa-exec into claude-bwrap
claude-bwrap (unconfined)                                                 # label of a command inside bwrap
0                                                                         # nested user namespace, root inside
```

- bwrap maps your own UID into the namespace (not root, unlike `--map-root-user`); groups without a mapping show as `nogroup`.
- `claude-bwrap` is exactly the kind of profile the 2025 Qualys bypass abused (unconfined + `userns`). `kernel.apparmor_restrict_unprivileged_unconfined = 1` (role `common`) stops an unprivileged process from entering it with `aa-exec`, the same as for `trinity`. bwrap works with that restriction on.
- **Commands inside bwrap inherit the profile.** A process started inside reads `claude-bwrap (unconfined)` from `/proc/self/attr/current` and can create a nested user namespace with full capabilities. The documentation says the profile "applies only to bwrap itself, not to the commands it runs inside the sandbox"; with this profile form (the same as the documented one) that is not what happens. Whether Claude Code closes it (e.g. bwrap's `--disable-userns`) is checked with a real sandboxed command in step 16.

---

# Part 3 — Managed settings

## Step 13/33 — What the managed settings enforce (decisions)

**Why:** managed settings (`/etc/claude-code/managed-settings.json`, root-owned) are the one level that neither the user's settings, nor a repository's `.claude/`, nor Claude itself (through its file tools) can change without root. Everything that is a security decision goes there.

**Check first which secrets exist** (node, no root; names only, no values):

```bash
env | cut -d= -f1 | grep -iE 'token|key|secret|pass|auth|cred' || echo "(none)"
ls -ld ~/.aws ~/.docker/config.json ~/.config/gh ~/.kube ~/.netrc ~/.git-credentials ~/.npmrc ~/.pypirc
```

**Result:** none of those credential files exist on the node. One variable looks like a secret: `CLAUDE_CODE_MESSAGING_TOKEN`, which Claude Code puts into the environment of the commands it runs (it is not in the login shell); sandboxed commands have no use for it.

**Decisions:**

- **Fixed by earlier steps and the documentation:** `requiredMinimumVersion: "2.1.285"`, `env.DISABLE_UPDATES: "1"` (step 9), `permissions.disableBypassPermissionsMode: "disable"`, `sandbox.enabled`, `failIfUnavailable: true`, `allowUnsandboxedCommands: false`, `bwrapPath: /usr/local/bin/claude-bwrap` (step 5a), `network.allowManagedDomainsOnly` and `strictAllowlist`, `filesystem.allowManagedReadPathsOnly`. Without the two `allowManaged…Only` locks, user settings and saved "Yes, and don't ask again" approvals (`WebFetch(domain:…)` rules) would widen the sandbox's allowlist and read paths.
- **Sandbox mode and permission mode:**

  | Option | How it works | Trade-off |
  |---|---|---|
  | **A1 (chosen):** Manual mode + `autoAllowBashIfSandboxed: true` | Sandboxed commands run without a prompt (the sandbox is the boundary); file edits by Claude's Edit/Write tools still prompt | Bash can change files in the repo without a prompt; every diff is still reviewed before a commit, and nothing outside the repo is writable |
  | A2: Manual + `autoAllowBashIfSandboxed: false` | Every command prompts, sandboxed or not | Most control, most prompts |
  | A3: Auto mode + sandbox | A classifier approves, the sandbox contains | The model decides, not the user |

- **Secrets hidden** from sandboxed commands (`sandbox.credentials`, `filesystem.denyRead`) **and** from the file tools (`permissions.deny` `Read(...)`, because the file tools run outside the sandbox): `~/.ssh` (step 4), `~/.aws` (pre-emptively), every `.env` under the home directory, Claude Code's own OAuth token `~/.claude/.credentials.json` (the sandbox protects `~/.claude` from writes, not from reads), and the variable above. `permissions.blockReadsOutsideWorkingDirectories` was not used: labs read `/etc` and other system files.
- **Allowed domains:** only what read-only version checks need: `pypi.org`, `registry.npmjs.org`, `downloads.claude.ai`, `api.github.com`. Git over the network and Ansible are run by the user, outside the sandbox; documentation is read with WebFetch, which does not use this list.
- **Read rule syntax** (code.claude.com/docs/en/permissions): `~/path` is relative to the home directory, `//path` is absolute, `/path` is relative to the settings file's location; `**` matches any depth. A `Read` deny rule covers the Read tool, Grep and Glob (best effort) and file commands Bash recognises (`cat`, `head`, …), but not a script that opens files itself; the sandbox covers that.

## Step 14/33 — The role, part 3: managed settings

**Why:** deploy the policy from step 13 as a root-owned file that no lower settings level can loosen.

**Files:**

- `roles/claude_code/files/managed-settings.json`: the policy (full text in the role; validated with `python3 -I -m json.tool`).
- `roles/claude_code/tasks/main.yml`: `/etc/claude-code` (root:root `0755`) and `copy` of the file to `/etc/claude-code/managed-settings.json` (root:root `0644`). It must stay world-readable: Claude Code starts **without** a managed file it cannot read, and reports that only in `/status` and `claude doctor`.
- `roles/claude_code/README.md`: a table of every key and why it is there.

**Command** (lint on both control points, then from the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

**Expected / Result:** lint `16 files processed of 27 encountered`, clean. Check and real run both `ok=17 changed=2 skipped=1`: `/etc/claude-code` (`"state": "absent"` → `"directory"`) and the settings file (diff from `(absent)`).

**Does a running session pick it up?** Checked from inside the running session, before and after the real run, with a command that shows whether it runs in the sandbox (step 12 showed that commands inside `claude-bwrap` carry its AppArmor label, and sandboxed commands get proxy variables):

```bash
cat /proc/self/attr/current; echo; env | grep -iE '^(https?|all)_proxy=' || echo "(no proxy vars)"
```

Before and after: `unconfined` and `(no proxy vars)`. The file was on disk (`-rw-r--r-- root root 1144`), but the running session did not start sandboxing its commands: **restart Claude Code after changing the sandbox policy** (step 15).

## Step 15/33 — Restart, and check that the policy is in force

**Why:** Claude Code reads the sandbox policy, checks the dependencies (`failIfUnavailable`) and the version (`requiredMinimumVersion`) at start-up.

**Command** (node): `/exit`, then `cd <repo> && claude --continue`. In the new session: `/status`, `/sandbox`, and ask Claude to run the label check from step 14.

**Result:**

- Claude Code starts. `/status` → `Setting sources: User settings, Enterprise managed settings (file)`: a file-based managed policy applies on a Pro account too (`claude doctor`'s "Organization policy: not applicable to Pro and Max accounts" refers to server-managed settings from claude.ai).
- `/sandbox` does not open: `Error: Sandbox settings are overridden by a higher-priority configuration and cannot be changed locally.` This is documented behaviour when a higher level sets `enabled`, `autoAllowBashIfSandboxed` or `allowUnsandboxedCommands`: the panel would save to `.claude/settings.local.json`, which cannot override managed settings.
- `/status` → System diagnostics: `Glob patterns in sandbox permission rules are not fully supported on Linux`. On Linux a glob in a sandbox path is expanded into the matching files **when each command starts** (step 18); the resolved read-deny list shows `~/**/.env` as the one `.env` that existed (`/home/<user>/<project>/.env`). Explicit paths (`~/.ssh`, `~/.aws`) need no expansion.
- The label check, now sandboxed:

  ```
  claude-bwrap (unconfined)
  HTTPS_PROXY=http://srt.<base64>:<secret>@localhost:3128      (also HTTP_PROXY, ALL_PROXY, lower case)
  ```

  The command runs under the bwrap copy (`bwrapPath` works). `localhost:3128` is inside the command's own network namespace; socat relays it to Claude Code's proxy outside. The proxy URL carries credentials: the user part is the base64 of the tool call ID (`toolu_…`), so the proxy can attribute every request to one command; the password keeps other local processes from using the proxy.

---

# Part 4 — Probe matrix

All probes are run **by Claude in its sandbox** (a command you type at the `!` prompt runs outside the sandbox and proves nothing).

## Step 16/33 — Filesystem and process probes

**Why:** the first criterion: writes outside the allowed directories fail, protected paths stay read-only inside the working directory, and a sandboxed process has no privileges.

**Commands** (Claude, sandboxed; a probe that unexpectedly succeeds creates an empty file, which is then deleted):

```bash
touch ~/sandbox-probe; echo "exit=$?"
touch .git/hooks/sandbox-probe; echo "exit=$?"; touch sandbox-probe-ok && rm sandbox-probe-ok && echo "repo root: writable"
grep -E '^(NoNewPrivs|Seccomp|CapEff|CapBnd)' /proc/self/status; id
unshare --user --map-root-user sh -c 'id -u; grep CapEff /proc/self/status'; echo "exit=$?"
```

**Result:**

```
touch: cannot touch '/home/<user>/sandbox-probe': Read-only file system
exit=1
touch: cannot touch '.git/hooks/sandbox-probe': Read-only file system
exit=1
repo root: writable
CapEff:	0000000000000000
CapBnd:	000001ffffffffff
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1
uid=1000(<user>) gid=1000(<user>) groups=1000(<user>),65534(nogroup)
0
CapEff:	000001ffffffffff
exit=0
```

- The home directory is mounted read-only; the working directory is writable; `.git/hooks` inside it is not (a hook written there would run at your next `git commit`, outside the sandbox).
- No effective capabilities, `no_new_privs` set (setuid programs such as `sudo` cannot raise privileges), one seccomp filter (the optional filter that blocks Unix sockets). `nogroup` shows the process is in a user namespace. The bounding set is **not** cleared.
- **A sandboxed command can create a nested user namespace and be root with full capabilities inside it.** It stays inside bwrap's mount and network namespaces (the home directory stays read-only, network still only through the proxy), so this is not an escape by itself. But it re-opens what `kernel.apparmor_restrict_unprivileged_userns` closes on Ubuntu: kernel code that otherwise needs root (netfilter, some filesystems), the usual path of local privilege escalation bugs. Cause: commands inside bwrap inherit the `claude-bwrap` profile, which allows `userns` (step 12), and Claude Code 2.1.287 does not pass bwrap's `--disable-userns`. The documented profile for `/usr/bin/bwrap` has the same effect.

## Step 17/33 — Can Ubuntu's stacked profile close the gap?

**Why:** step 16 showed that a sandboxed command can become root with full capabilities in a nested user namespace, because everything bwrap runs inherits the `claude-bwrap` profile and its `userns` permission. Ubuntu addresses the same problem for bwrap with an experimental profile, `bwrap-userns-restrict` (package `apparmor-profiles`, `/usr/share/apparmor/extra-profiles/`, disabled by default on noble; enabled by default from Ubuntu 26.04).

**How it works** (git.launchpad.net/ubuntu/+source/apparmor, `profiles/apparmor/profiles/extras/bwrap-userns-restrict`, branch `applied/ubuntu/noble-updates`): the `bwrap` profile allows `capability`, `userns` and mounts for bwrap's own setup, and stacks every program bwrap executes with `unpriv_bwrap` (`allow px /** -> bwrap//&unpriv_bwrap`), which has `audit deny capability`. In a stack the intersection applies, so sandboxed programs can never use a capability, not even in a nested user namespace. A stack instead of a plain transition, because bwrap sets `no_new_privs`, under which only narrowing transitions are allowed.

**Test:** the same two profiles, adapted to the copy (`claude-bwrap` and `claude-bwrap-unpriv`, `allow px /** -> claude-bwrap//&claude-bwrap-unpriv`), deployed through the role, then any sandboxed command.

**Result: incompatible with Claude Code's sandbox.** No sandboxed command starts:

```
apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted; caller must provide CAP_SYS_ADMIN): Permission denied
apparmor="DENIED" operation="capable" class="cap" profile="claude-bwrap-unpriv" pid=… comm="3" capability=21  capname="sys_admin"
```

- `apply-seccomp` is a helper of Claude Code's sandbox runtime: bwrap starts it inside the sandbox, it creates **its own nested user namespace** to install the seccomp filter, and needs `CAP_SYS_ADMIN` there. The runtime relies on exactly what the stacked profile denies.
- `comm="3"`: the helper is executed from a file descriptor (`/proc/self/fd/3`, step 22), it has no path on disk, so AppArmor (path-based) cannot give it a narrow exception.
- It fails closed: with `allowUnsandboxedCommands: false` nothing runs outside the sandbox either.

**Known upstream** (checked 2026-10-14): anthropics/claude-code#87680 reports the same denial on Ubuntu 26.04, where the profile is enabled by default and the sandbox does not start at all; anthropics/sandbox-runtime#428 explains why `apply-seccomp` nests a user namespace, and the proposed fixes are in the runtime. The workaround in circulation, `priority=1 capability sys_admin,` in `/etc/apparmor.d/local/unpriv_bwrap`, gives the capability back to bwrap's children and so re-opens the same gap, for every bwrap user. bwrap's own `--disable-userns` cannot help either: the runtime itself needs the nested namespace.

**Decision:** keep the simple profile from step 11 and document the gap (also in the role's README). Sandboxed commands can create nested user namespaces with capabilities inside them; the filesystem and network boundaries still hold, the kernel attack surface stays open. Closing it is left to Lab 11 (Landlock + seccomp by hand, gVisor), where it is one of the attacks to test.

## Step 18/33 — Credential probes

**Why:** by default the sandbox can read almost everything, `~/.ssh` included. Check every secret the managed settings deny, without ever printing one: count directory entries, count bytes, report a variable as present or absent. A protection that fails shows a real size, not a secret.

**Commands** (Claude, sandboxed; the canary files live in the gitignored `work/`):

```bash
echo "~/.ssh entries: $(ls -A ~/.ssh 2>&1 | wc -l)"; for f in ~/.ssh/config ~/ghostwheel/.env ~/.claude/.credentials.json; do printf '%s: ' "$f"; wc -c < "$f" 2>&1; done
env | grep -q '^CLAUDE_CODE_MESSAGING_TOKEN=' && echo "token var: present" || echo "token var: absent"
```

**Result:**

```
~/.ssh entries: 0
/home/<user>/.ssh/config: No such file or directory
/home/<user>/ghostwheel/.env: Permission denied
/home/<user>/.claude/.credentials.json: Permission denied
token var: absent
```

A denied **directory** is covered by an empty one (the command sees nothing, not even that something is hidden); a denied **file** is covered by an unreadable bind mount. The variable is removed from the environment of sandboxed commands. Claude Code's own OAuth token file is protected too.

**`.env` files and the glob `~/**/.env`** — the layers answer differently:

| Attempt (canary `work/lab0f-canary/.env`, created after the session started) | Result | Layer |
|---|---|---|
| `wc -c < work/lab0f-canary/.env` | the whole Bash call is refused before it runs | permission rules: `Read(...)` deny rules also cover input redirects (`< file`) of Bash commands |
| `python3 -I -c 'print(len(open("work/lab0f-canary/.env").read()))'` | `PermissionError: [Errno 13] Permission denied` | sandbox |
| Read tool on the same file | `File is in a directory that is denied by your permission settings.` | permission rules (file tools run outside the sandbox) |
| One Python command that creates **and** reads `work/lab0f-canary/b/.env` | `20` (readable) | none |

- The permission layer sees only paths written in the command text; a script that opens files itself passes it. The sandbox catches it.
- On Linux a glob in a sandbox path is **expanded when each command starts** (`/status`: "Glob patterns in sandbox permission rules are not fully supported on Linux"). A file that appears while a command is running, created by that command or by another process, is not covered. Explicit paths (`~/.ssh`, `~/.aws`) have no such gap; prefer them for anything that already exists.

## Step 19/33 — The escape hatch, the permission mode, and the `!` prompt

**Why:** by default a command that fails in the sandbox can be retried outside it (`dangerouslyDisableSandbox: true`). `allowUnsandboxedCommands: false` in managed settings is supposed to make Claude Code ignore that parameter.

**Command** (Claude, requesting `dangerouslyDisableSandbox: true`):

```bash
touch ~/sandbox-probe; echo "exit=$?"; cat /proc/self/attr/current
```

**Result:**

- **In auto mode** the request is refused before the sandbox is involved: `Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Safety Bypass Flag]`. The classifier is a separate layer. Managed settings that enforce the sandbox do not set the permission mode: a resumed session keeps the mode it had, so `permissions.defaultMode` is set in managed settings (decision below).
- **In manual mode** (Shift+Tab): a regular permission prompt titled `Bash command`, not `Bash command (unsandboxed)` (the documented title of an unsandboxed retry). Approved once (option 1, no rule saved):

  ```
  touch: cannot touch '/home/<user>/sandbox-probe': Read-only file system
  exit=1
  claude-bwrap (unconfined)
  ```

  The parameter is ignored and the command runs sandboxed. A command that requests the escape hatch goes through the regular permission flow (no auto-allow), then runs in the sandbox anyway.

**The `!` prompt** (typed by the user in the session; it creates and removes a file in the home directory):

```
! cat /proc/self/attr/current; echo; touch ~/sandbox-probe-bang && ls -l ~/sandbox-probe-bang && rm ~/sandbox-probe-bang && echo "removed"
```

**Result:** `unconfined`, the file is created in the home directory and removed. Commands typed at `!` run with the user's full access, outside the sandbox, even with `allowUnsandboxedCommands: false` (documented; exceptions: background sessions and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` on Linux). Not a gap for Claude, which cannot type there, but `!` is useless for testing the sandbox.

**Decision: how to make the chosen manual mode stick.**

| Option | Effect | Trade-off |
|---|---|---|
| (1) `permissions.disableAutoMode: "disable"` in managed settings | Auto mode removed from the Shift+Tab cycle on this host | Using auto mode later needs a role change |
| **(2) chosen:** `permissions.defaultMode: "default"` in managed settings | Sessions start in manual mode; auto mode stays available on purpose with Shift+Tab | Nothing is enforced; the choice is per session |
| (3) Nothing | Shift+Tab per session | A resumed session can come back in auto mode, as seen here |

Key names and values were checked against the raw documentation pages (`permissions.disableAutoMode` / `permissions.disableBypassPermissionsMode` take the string `"disable"`; `permissions.defaultMode` takes `default`, `acceptEdits`, `plan`, `auto`, …); a summarised fetch of the settings reference got both wrong.

## Interlude — Is all this control worth it, if the gap cannot be closed?

A fair question after step 17: if Ubuntu's model cannot be applied, why not just use Claude Code's built-in sandbox options and stop there? And could we not allow everything except "the command" that opens the gap?

**1. This *is* the built-in sandbox.** Nothing was added on top of it. Around it there are three things, and each has a reason:

| What | Why | Without it |
|---|---|---|
| bubblewrap, socat and an AppArmor exception for bwrap | Required on Ubuntu 24.04 | The built-in sandbox does not start at all (step 10) |
| The built-in options in `/etc/claude-code/managed-settings.json` instead of `~/.claude/settings.json` | Same options; but root-owned, so neither a repository nor Claude (through its file tools, with one approval) can loosen them | Claude can propose an edit to the user settings, and one "Yes" opens the sandbox |
| An Ansible role | Repeatable; a new node is one playbook run | Manual steps per node |

The nested user namespace gap is not caused by this control. It is in the built-in sandbox itself: the documented profile for `/usr/bin/bwrap` (`flags=(unconfined)` + `userns`) has exactly the same effect, and for every program on the host that runs bwrap, not only for one dedicated copy. The probes found it; without them it would be there unnoticed.

**2. There is no single command to block.** `unshare` is a thin wrapper around the system call `unshare(CLONE_NEWUSER)`; `python3 -c 'import os; os.unshare(os.CLONE_NEWUSER)'`, a small C program or any tool that makes the call does the same. So:

- A permission rule `Bash(unshare *)` is only a speed bump: it stops the literal command, not a script, and gives a false sense of safety. Not used.
- AppArmor attaches by path; Claude Code's helper that needs the nested namespace (`apply-seccomp`) has no path (`comm="3"`, step 17), so a narrow exception for it cannot be written.
- The right tool is a **seccomp filter** that denies `CLONE_NEWUSER` to the command. That filter is installed by Claude Code's own `apply-seccomp`; adding the rule there is one of the fixes proposed in anthropics/sandbox-runtime#428. It cannot be done from outside.

**3. What reduces the risk now.** The gap matters only if the kernel has an **unpatched** bug reachable through user namespaces (the usual route of local privilege escalation). The practical defence is an up-to-date kernel and AppArmor: at the time of the lab the node had 54 pending updates, `apparmor` among them. That belongs to the security-update policy of Lab 1. Closing the gap for good belongs to Lab 11 (Landlock + seccomp by hand, gVisor), where it is one of the attacks to test.

What the built-in sandbox does deliver, proven by the probes: no writes outside the repository and the temp directory, protected paths read-only inside the repository, secrets unreadable, no network except four allowed hosts through the proxy, no unsandboxed retry, and a refusal to start without it.

## Step 20/33 — Network probes

**Why:** the second criterion. A sandboxed command has its own network namespace with no route out; the only exit is Claude Code's proxy, which allows four hosts.

**Commands** (Claude, sandboxed):

```bash
curl --noproxy '*' -sS -m 10 -o /dev/null https://example.com; echo "exit=$?"; ip -br addr
curl -sS -m 10 -o /dev/null -w 'http=%{http_code}\n' https://example.com; echo "exit=$?"
curl -sS -m 10 -o /dev/null -w 'http=%{http_code} remote=%{remote_ip}:%{remote_port}\n' https://pypi.org/simple/; echo "exit=$?"
```

**Result:**

```
curl: (6) Could not resolve host: example.com          # direct: no DNS, no route
exit=6
lo               UNKNOWN        127.0.0.1/8 ::1/128     # the only interface

curl: (56) CONNECT tunnel failed, response 403         # through the proxy, host not allowed
http=000
exit=56

http=200 remote=::1:3128                               # through the proxy, allowed host
exit=0
```

- The disallowed host is refused **without a prompt** (`strictAllowlist`, `allowManagedDomainsOnly`). Claude also receives the reason in its tool result: `deny network-outbound example.com:443 (host is not on the allow list)`.
- The allowed host is the control: without it, "blocked" could also mean "the proxy blocks everything".
- curl only ever sees the proxy (`::1:3128`, inside the command's own network namespace), never the real address.

**Permission prompts during the probes.** In manual mode most sandboxed probes still asked for approval, the `curl` probes did not. The prompts offered rules for paths outside the working directory (e.g. `/proc/<pid>/attr`): the permission layer checks the paths of file commands it recognises even for sandboxed commands, while auto-allow only skips the question whether the command may run. Saving such a rule ("Yes, and don't ask again") was avoided: it persists outside the role, unreviewed, and a pattern like `Bash(curl *)` covers far more than the one command seen. A deliberate, narrow allowlist is step 28.

## Step 21/33 — File tools outside the sandbox

**Why:** Claude's Read, Edit and Write tools do not run through bwrap; only permission rules stand in their way. `sandbox.credentials` protects nothing here.

**Command** (Claude, Read tool): read `~/.ssh/config`.

**Result:** `File is in a directory that is denied by your permission settings.` The `Read(~/.ssh/**)` rule in managed settings stops the tool before it opens the file; without it the Read tool would read it, sandbox or not. (Same result for the `.env` canary in step 18.) Every secret therefore needs two entries: one in `sandbox.credentials` / `filesystem.denyRead` for commands, one `Read(...)` deny rule for the file tools.

## Step 22/33 — The sandbox from outside: `ps`, `lsns`, and bwrap's arguments

**Why:** recognise the namespaces from Lab 0a in a real sandbox, and read the actual policy Claude Code hands to bwrap. From inside, a command sees only its own world, so this is done from another terminal.

**Command:** Claude starts a sandboxed `sleep 300 #lab0f-probe` in the background; then, in another terminal on the node (no root; `lsns` and `/proc` show your own processes):

```bash
p=$(pgrep -n -f 'lab0f-probe'); ps -o pid,ppid,comm,args --forest -s $(ps -o sid= -p $p) | cut -c1-150
lsns -p $p -o NS,TYPE,PID,COMMAND; lsns -p $$ -o NS,TYPE
a=$(tr '\0' '\n' < /proc/$(pgrep -n -x claude-bwrap)/cmdline)
echo "$a" | grep -E '^--' | sort | uniq -c | sort -rn
echo "$a" | grep -A2 -E '^--(ro-bind|bind|tmpfs)$' | grep -vE 'srt\.|^--$' | paste - - -
```

The last two lines leave out the proxy URLs: they carry the session's proxy password.

**Result — process tree:**

```
claude-bwrap --new-session --die-with-parent --unsetenv CLAUDE_CODE_MESSAGING_TOKEN …
 └─ bash -c socat …
     ├─ socat TCP-LISTEN:3128,fork,reuseaddr UNIX-CONNECT:/tmp/claude-http-<id>.sock   # HTTP proxy bridge
     ├─ socat TCP-LISTEN:1080,fork,reuseaddr UNIX-CONNECT:/tmp/claude-http-<id>.sock   # SOCKS bridge
     └─ 3  (/proc/self/fd/3 …)          # apply-seccomp, executed from a file descriptor
         └─ 3                           # its child after the nested unshare
             └─ bash -c … source ~/.claude/shell-snapshots/snapshot-bash-….sh …
                 └─ sleep 300
```

- Two `socat` processes inside the sandbox listen on `localhost:3128` and `:1080` and forward to a Unix socket that leads to Claude Code's proxy outside. They start **before** `apply-seccomp`: the seccomp filter blocks Unix sockets, so the bridge must already be up when the filter is applied to the command.
- `apply-seccomp` appears as `3` (`/proc/self/fd/3`): the same pathless helper as `comm="3"` in step 17.
- The command's shell loads a snapshot of the user's shell environment (`PATH`, aliases).

**Result — namespaces of `sleep` vs. the user's shell:**

| Type | sleep | user's shell | Created by |
|---|---|---|---|
| net | 4026533171 | 4026531833 | bwrap |
| user | 4026533229 | 4026531837 | `apply-seccomp` (the nested one) |
| mnt | 4026533230 | 4026531832 | `apply-seccomp` |
| pid | 4026533231 | 4026531836 | `apply-seccomp`'s child |
| time, cgroup, uts, ipc | 4026531834–39 | same | shared with the host |

The command's user namespace was created by `apply-seccomp`, not by bwrap: the nested namespace of steps 16–17, seen from outside (bwrap's own user namespace is its parent, so `lsns -p` on the command does not list it). 4026531832–39 are the host's initial namespaces (fixed numbers, Lab 0a). Unlike `minicontainer.sh` (Lab 0a: new uts, pid, mnt, ipc, cgroup, net), the sandbox shares ipc, uts and cgroup with the host.

**Result — bwrap's arguments** (`uniq -c` of the options): 38 `--ro-bind`, 31 `--setenv`, 4 `--tmpfs`, 4 `--bind`, one each of `--unshare-user`, `--unshare-pid`, `--unshare-net`, `--unsetenv`, `--proc`, `--dev`, `--cap-drop`, `--new-session`, `--die-with-parent`. No `--disable-userns`, no `--unshare-ipc`/`--unshare-uts`/`--unshare-cgroup`.

How the filesystem is assembled (order matters, later mounts cover earlier ones):

1. `--ro-bind / /`: the whole host, read-only (hence "reads almost everything by default").
2. `--bind` for what is writable: the repository, `/tmp/claude-1000` (`$TMPDIR`), `~/.npm/_logs`, and the proxy's Unix socket.
3. Protected paths re-mounted read-only on top: `.git/hooks`, `.git/config`, `.claude`.
4. A denied **directory**: `--tmpfs ~/.ssh` (an empty filesystem on top: 0 entries, step 18). Also `--tmpfs /etc/ssh/ssh_config.d`.
5. A denied **file**: `--ro-bind /dev/null <file>`, for `.env`, `.credentials.json`, and for protected paths that do not exist yet (`.bashrc`, `.zshrc`, `.mcp.json`, `.claude/settings.json` in the repository): the placeholders the documentation mentions. Reading one gives `Permission denied` rather than 0 bytes, most likely because mounts inherited into an unprivileged user namespace become `nodev`, so `/dev/null` cannot be opened there.

The environment (`--setenv`) points every protocol it can at the proxy: `HTTP(S)_PROXY`, `ALL_PROXY`, `GRPC_PROXY`, `FTP_PROXY` and `RSYNC_PROXY` (SOCKS), `DOCKER_HTTP(S)_PROXY`, and `GIT_SSH_COMMAND` with a `socat` `ProxyCommand` (git over SSH tunnels through the proxy on port 3128). `NO_PROXY` lists loopback and the private ranges (10/8, 172.16/12, 192.168/16, 169.254/16), which a sandboxed command still cannot reach directly: its network namespace has no route. The repository is marked `safe.directory` through `GIT_CONFIG_*` variables, not through `.gitconfig`.

## Step 23/33 — Ollama on `localhost:11434` (architecture decision)

**Why:** Ollama runs on the host. On Linux a sandboxed command's `localhost` is its own; `NO_PROXY` (step 22) sends `localhost` direct, into that private loopback.

**Commands** (Claude, sandboxed):

```bash
curl -sS -m 5 http://localhost:11434/api/version; echo "exit=$?"
curl -sS -m 5 --noproxy '' --proxy "$HTTP_PROXY" -w '\nhttp=%{http_code}\n' http://127.0.0.1:11434/api/version; echo "exit=$?"
```

The second forces the request through the proxy (`--noproxy ''` disables `NO_PROXY`): the proxy runs on the host and *could* reach Ollama.

**Result:**

```
curl: (7) Failed to connect to localhost port 11434 after 0 ms: Couldn't connect to server
exit=7
Connection blocked by network allowlist
http=403
exit=0
```

Direct: nothing listens on 11434 in the command's own loopback. Through the proxy: refused, `127.0.0.1:11434` is not on the allowlist (curl's exit code is 0 because it got an HTTP answer; read `http=`).

**Decision:**

| Option | How | For | Against |
|---|---|---|---|
| **(a) chosen:** no access | Nothing | No risk; no lab needs Claude to call Ollama yet | Claude cannot test model calls itself |
| (b) `"127.0.0.1:11434"` in managed `allowedDomains` | Commands must go through the proxy explicitly (`NO_PROXY` sends `localhost` direct) | Stays sandboxed, one port only | Ollama's API has no authentication: pull, delete, load the GPUs |
| (c) `excludedCommands` for one client + an ask rule | The command runs outside the sandbox, approved each time | No proxy tricks | Full access for that command, not only to Ollama |

Revisit in Lab 8: with a gateway (LiteLLM, virtual keys, budgets) in front of Ollama and vLLM, the allowlist gets the gateway and a key with narrow rights, not Ollama's bare API.

This affects only the commands Claude Code runs in its sandbox. Ollama, Docker containers and other services on the host reach each other as before.

**Working on another project in the meantime** (for example a bot that needs a token from `.env`, Discord and Ollama): the managed settings apply to every Claude Code session on the host. Claude can edit the code, commit and run tests that need no network; it cannot read the project's `.env`, reach external services or Ollama, or run `docker` (the Docker socket is a Unix socket, blocked by the seccomp filter). The practical split is the one used in this lab: Claude writes and tests, the user runs the service. To let Claude run, say, `docker compose up`, add `excludedCommands: ["docker compose *"]` with an ask rule, deliberately, in the managed settings. A repository's `.claude/settings.json` cannot add it (admin-required sandbox), but the user's own `~/.claude/settings.json` can: per the documentation, `excludedCommands` and `filesystem.allowWrite` have no managed-only lock. Claude can only propose an edit to that file (a protected path, through a prompt); the decision stays with the user.

## Step 24/33 — Ansible and `ssh` from the sandbox (architecture decision)

**Why:** Ansible connects over SSH, and plain `ssh` ignores the proxy variables; `~/.ssh` is hidden as well.

**Command** (Claude, sandboxed):

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com; echo "exit=$?"
```

**Result:** `ssh: Could not resolve hostname github.com: Temporary failure in name resolution`, `exit=255`. No DNS, no route, no keys. (The `GIT_SSH_COMMAND` tunnel of step 22 applies only to `git`.)

**Decision:**

| Option | For | Against |
|---|---|---|
| **(1) chosen:** Claude writes, the user runs | Real runs, become and keys stay with the user; connection-free checks still work in the sandbox with `ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp"` | Every run is manual |
| (2) `excludedCommands: ["ansible-playbook *"]` + an ask rule in managed settings | Claude can start a playbook after approval | The command runs outside the sandbox with full access (SSH keys, sudo on the managed hosts); the pattern covers every playbook, and playbooks live in the repository Claude writes. The documentation warns about exactly this kind of entry |

The control node is the laptop anyway (Lab 0g): Ansible runs from there, outside any Claude Code session.

## Step 25/33 — GPU inside the sandbox

**Why:** do `nvidia-smi` and CUDA work inside bwrap? bwrap's arguments (step 22) include `--dev /dev`: a minimal `/dev`, not the host's.

**Commands** (Claude, sandboxed):

```bash
ls /dev; ls -l /dev/nvidia* 2>&1 | head -3; nvidia-smi -L; echo "exit=$?"
python3 -I -c 'import ctypes; c=ctypes.CDLL("libcuda.so.1"); n=ctypes.c_int(); print("cuInit:", c.cuInit(0), "cuDeviceGetCount:", c.cuDeviceGetCount(ctypes.byref(n)), "devices:", n.value)'
```

The second calls the CUDA driver API through `ctypes`, nothing to install.

**Result:**

```
core fd full null ptmx pts random shm stderr stdin stdout tty urandom zero
ls: cannot access '/dev/nvidia*': No such file or directory
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. ...
exit=9
cuInit: 100 cuDeviceGetCount: 3 devices: 0
```

The driver library loads (it is part of the read-only root), but there are no device nodes: `cuInit` returns 100 (`CUDA_ERROR_NO_DEVICE`), the count 3 (`CUDA_ERROR_NOT_INITIALIZED`), 0 devices.

**Decision:**

| Option | For | Against |
|---|---|---|
| **(a) chosen:** no GPU in the sandbox | The agent cannot put arbitrary load on the cards; benchmarks stay with the user | Claude cannot even read `nvidia-smi` |
| (b) a narrow `excludedCommands` pattern such as `nvidia-smi --query-gpu=* --format=csv*` in managed settings | Claude sees temperature, VRAM, power | Runs outside the sandbox; prompts unless also allowed; patterns are brittle |
| (c) device nodes inside the sandbox | Full GPU access | No documented setting for extra devices; would mean working around the sandbox |

Revisit in Lab 2: GPU metrics will be in Prometheus, which Claude can read over HTTP once Prometheus is on the allowlist; the agent sees the state without touching the devices (the approach of the capstone, Lab 16). To loosen earlier, change the managed settings in the role (option b), not `~/.claude/settings.json`.

## Step 26/33 — The session refuses to start without the sandbox (deliberate drift)

**Why:** the last criterion. Without `failIfUnavailable`, a missing dependency makes Claude Code run commands **unsandboxed**. Two kinds of drift test two different things: a missing dependency (checked at start-up) and a sandbox that is installed but cannot work.

While a drift lasts, every sandboxed command of a running session fails too, so the test uses headless `claude -p` from a terminal. With `autoAllowBashIfSandboxed`, `-p` runs sandboxed commands without a prompt (nobody could answer one).

**Drift A — the bwrap copy not executable** (node, root, changes the node):

```bash
sudo chmod 0644 /usr/local/bin/claude-bwrap && cd <repo> && claude -p 'Run: echo sandbox-ok'; echo "exit=$?"
```

```
Error: sandbox required but unavailable: sandbox is enabled but dependencies are missing: bubblewrap (bwrap) not executable at /usr/local/bin/claude-bwrap · install missing tools (e.g. apt install bubblewrap socat) or see https://code.claude.com/docs/en/sandboxing
  sandbox.failIfUnavailable is set — refusing to start without a working sandbox.
exit=1
```

Claude Code refuses to start and says why. From the control node, `--check --diff` reports the bwrap copy task `changed` with no diff (`copy` does not show modes in diffs, Lab 0g); the real run restores `0755`, and `claude -p` works again (`sandbox-ok`, `exit=0`, no prompt).

**Drift B — the AppArmor profile removed from the kernel** (node, root; the file stays):

```bash
sudo apparmor_parser -R /etc/apparmor.d/claude-bwrap && cd <repo> && claude -p 'Run exactly: cat /proc/self/attr/current. Report the raw output or error.'
```

- Claude Code **starts**: its start-up check sees an executable binary at `bwrapPath`; it does not try to create a sandbox.
- The command fails **closed**: `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` (step 10), and it is not run outside the sandbox.
- **The first version of the role did not see it:** `--check --diff` gave `ok=17 changed=0`. The role compared the file, and the handler fires only when the file changes. The same gap as a sysctl changed at run time (Lab 0g, role `common`).

**Fix in the role** (same model as `common`: read the running state, apply when it differs):

```yaml
- name: Read the AppArmor profiles loaded in the kernel
  ansible.builtin.command: cat /sys/kernel/security/apparmor/profiles
  register: claude_code_loaded_profiles
  changed_when: false
  check_mode: false

- name: Load the claude-bwrap profile when it is missing from the kernel
  ansible.builtin.command:
    cmd: apparmor_parser -r /etc/apparmor.d/claude-bwrap
    # With removes, check mode reports "would run" as changed instead of skipping.
    removes: /etc/apparmor.d/claude-bwrap
  when: "'claude-bwrap' not in (claude_code_loaded_profiles.stdout_lines | map('regex_replace', ' \\(.*\\)$', '') | list)"
```

- `/sys/kernel/security/apparmor/profiles` lists one loaded profile per line (`claude-bwrap (unconfined)`); root only, hence through become.
- `regex_replace` strips ` (mode)` so the name is compared exactly (a substring test would also match `claude-bwrap-unpriv`).

**Result** with the profile removed again: check mode `ok=19 changed=1 skipped=1` (the load task `changed`); the real run loads it (`ok=19 changed=1 skipped=1`); a second run `ok=18 changed=0 skipped=2` (the load task `skipping`: idempotent); `claude -p 'Run: echo sandbox-ok'` works again, and sandboxed commands carry `claude-bwrap (unconfined)` again.

## Step 27/33 — What a repository cannot loosen

**Why:** a cloned repository brings its own `.claude/settings.json` and `.claude/settings.local.json`. Under an admin-required sandbox (managed `allowUnsandboxedCommands: false`), the documentation says Claude Code ignores the repository's attempts to loosen the sandbox. Proven here with a temporary local settings file.

**File** `<repo>/.claude/settings.local.json` (created by Claude with the Write tool: `.claude/` is a protected path, so it asks; `.gitignore` already ignores the file):

```json
{
  "sandbox": {
    "enabled": false,
    "excludedCommands": ["curl *"],
    "network": { "allowedDomains": ["example.com"] },
    "filesystem": { "allowWrite": ["~"] }
  }
}
```

Then restart Claude Code (sandbox settings are read at start-up) and run, sandboxed:

```bash
cat /proc/self/attr/current; echo; curl -sS -m 10 -o /dev/null -w 'http=%{http_code}\n' https://example.com; echo "curl exit=$?"; touch ~/sandbox-probe; echo "touch exit=$?"
```

**Result:**

```
claude-bwrap (unconfined)
curl: (56) CONNECT tunnel failed, response 403
http=000
curl exit=56
touch: cannot touch '/home/<user>/sandbox-probe': Read-only file system
touch exit=1
```

| Attempt in the repository's settings | Result |
|---|---|
| `"enabled": false` | still sandboxed |
| `"excludedCommands": ["curl *"]` | the approval prompt is titled `Bash command`, not `Bash command (unsandboxed)`; curl runs sandboxed |
| `"allowedDomains": ["example.com"]` | `deny network-outbound example.com:443 (host is not on the allow list)` |
| `"allowWrite": ["~"]` | `Read-only file system`; `~` is absent from the resolved write list |

**Clean-up** (the user: the file is read-only inside the sandbox and the Write tool cannot delete): `rm <repo>/.claude/settings.local.json && rmdir <repo>/.claude`.

What *does* still loosen it, per the documentation: managed settings, `--settings` on the command line, and the user's own `~/.claude/settings.json` for keys without a managed-only lock (`excludedCommands`, `filesystem.allowWrite`; step 23).

## Step 28/33 — A deliberate permission allowlist

**Why:** with sandbox auto-allow, most sandboxed commands still prompted during the probes, because the permission layer checks paths outside the working directory that file commands name (`cat /proc/...`, `touch ~/...`), and assignments computed at run time (`export X="$TMPDIR/..."`). Clicking "Yes, and don't ask again" would save broad rules outside git (step 20). Instead: a short list, decided once, versioned.

**What prompted and why:**

| Prompt | Cause |
|---|---|
| `cat /proc/self/...`, `grep ... /proc/self/status` | path outside the working directory |
| `touch ~/...`, `ls ~/.ssh` | path outside the working directory (probes) |
| `export ANSIBLE_LOCAL_TEMP="$TMPDIR/..."` | assignment computed at run time |
| `dangerouslyDisableSandbox` | escape hatch |
| `curl https://...` | no prompt: no path; the network is the sandbox's job |

**Decisions:**

- **Allow** system reads in the repository's `.claude/settings.json` (committed; applies to this repository only; a repository may add permission rules under an admin-required sandbox, it just cannot loosen the sandbox): `Read(//etc/**)`, `Read(//usr/share/**)`, `Read(//sys/**)`. Secrets in `/etc` (`shadow`) are protected by Unix permissions anyway.
- **Not** `Read(//proc/**)`. The Read tool runs **outside** the sandbox, and `/proc/<pid>/environ` of every process of the user is readable to the user: Claude Code's own session token, a bot's token. Without a rule that takes one approval; an allow rule would make it silent. The opposite, a deny rule `Read(//proc/**/environ)`, is not usable either: permission deny rules are merged into the sandbox and their globs are expanded at every command, and over `/proc` that is every process on the host, past bwrap's limit of 9000 arguments (about 3000 mounts). No rule then: in manual mode such a read asks for approval, and `CLAUDE.md` says not to approve it. Sandboxed commands cannot reach it anyway: they have their own PID namespace and a fresh `/proc` (step 22).
- **`git add` and `git commit` without a tool prompt:** `Bash(git add *)` and `Bash(git commit *)` in the repository's settings. Both already run inside the sandbox; the allow rules only remove the extra approval prompt. The review gate stays in the conversation: the diff and the exclusion check are shown, and nothing is committed before the user says so. `git push` stays with the user (deny rule, hidden deploy keys, `github.com` not on the allowlist).
- **Ansible in the sandbox without `export`:** `env.ANSIBLE_LOCAL_TEMP` in the repository's settings with a fixed path inside the sandbox's writable temp directory, `/tmp/claude-1000/ansible-tmp` (settings `env` values do not expand `$TMPDIR`).

**Files:**

```json
// <repo>/.claude/settings.json
{
  "permissions": { "allow": ["Read(//etc/**)", "Read(//usr/share/**)", "Read(//sys/**)", "Bash(git add *)", "Bash(git commit *)"] },
  "env": { "ANSIBLE_LOCAL_TEMP": "/tmp/claude-1000/ansible-tmp" }
}
```

Commit with explicit paths (`git add .claude/settings.json …`), never `git add .` from inside the sandbox: its placeholders show up as untracked files there (step 27).

---

# Part 5 — Hooks, CLAUDE.md, headless

## Step 29/33 — Hooks and the status line

**Why:** hooks are commands Claude Code runs on events such as every tool call (code.claude.com/docs/en/hooks, 2026-10-14). They run **outside** the sandbox, with Claude Code's environment and the user's access. A hook defined in a cloned repository's `.claude/settings.json` would therefore run with full access; the sandbox does not cover it.

**Decisions:**

- **`allowManagedHooksOnly: true`, and no managed hooks.** Only hooks from managed settings may run, and there are none, so no repository and no user setting can add one. One line of configuration instead of code.
- **No guard or audit hook of our own.** A guard reads the command text, like permission rules; it adds no boundary, and a long script in a public repository is more surface to review than protection. What it would block goes into two declarative deny rules in managed settings: `Bash(sudo *)` and `Bash(git push *)` (inside the sandbox `sudo` is powerless anyway, `no_new_privs`, and there is no SSH key for a push). The audit trail is Claude Code's own transcript of every session (`~/.claude/projects/<project>/*.jsonl`; a protected path for sandboxed commands).
- **The status line.** `allowManagedHooksOnly` also restricts `statusLine` to managed settings, so managed settings point at the user's existing script, which stays in the home directory and out of the repository:

  ```json
  "allowManagedHooksOnly": true,
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
  ```

  The role installs `jq`, which the script uses.

**Command:** lint, check and real run from the control node, then restart Claude Code.

## Step 30/33 — Tests

**Commands** (Claude):

```bash
git push --dry-run origin main
```

and the Read tool on `/etc/hostname`.

**Result:**

- `git push` is refused by the permission rule before it runs.
- `/etc/hostname` is read without a prompt (`Read(//etc/**)`, step 28).
- The status line appears again after the restart, from the managed `statusLine`.

## Step 31/33 — CLAUDE.md for sessions on the node, and headless `claude -p`

**Why:** the sandbox changes how Claude has to work in this repository; the rules belong where every session reads them.

**Added to `CLAUDE.md`** (section "Claude Code on z790"): commands run in the sandbox (home read-only, network only through the allowlist, no SSH, Ollama or GPU); stage explicit paths, never `git add -A` or `git add .` (the sandbox's placeholders show up as untracked files inside it); Claude writes Ansible, the user runs it (connection-free checks work in the sandbox; `ANSIBLE_LOCAL_TEMP` comes from `.claude/settings.json`); changes to the files that define the sandbox (`managed-settings.json`, `claude-bwrap`) are called out for review; no deny globs over large trees; do not approve reads of `/proc/<pid>/environ`.

**Headless** (from step 26): `claude -p 'Run: echo sandbox-ok'` runs the command in the sandbox without a prompt (sandbox auto-allow; nobody could answer one), and refuses to start when the sandbox is unavailable (`failIfUnavailable`).

## Step 32/33 — Commit attribution

**Why:** decide whether Claude Code's commits carry its `Co-Authored-By` trailer.

**Decision:** keep the default trailer, as on every commit in this repository so far. To change it, `attribution.commit` (an empty string hides it; `includeCoAuthoredBy` is deprecated) in the repository's `.claude/settings.json`.

## Step 33/33 — Final run

**Why:** the whole site must lint clean and be idempotent with the finished role.

**Command** (both control points, then the control node):

```bash
ansible-playbook site.yml --syntax-check && ansible-lint
ansible-playbook site.yml --limit z790 --check --diff
```

**Expected / Result:** lint `Passed: 0 failure(s), 0 warning(s)`, profile `production`; check mode `changed=0`.

---

## Gotchas

- **Restart after changing the sandbox policy.** A running session keeps its sandbox configuration; `claude --continue` resumes the conversation.
- **The first `--check` on a new host fails at the Claude Code package** (step 8): expected.
- **`claude doctor` advises `claude install` after the switch to the package** (step 9): do not follow it.
- **Commands inside bwrap inherit its AppArmor profile** and can create a nested user namespace (steps 12, 16); Ubuntu's stacked profile breaks Claude Code's sandbox (step 17).
- **Check the loaded AppArmor profile, not only the file** (step 26).
- **No deny globs over large trees** (`/proc`): deny rules are merged into the sandbox and expanded at every command; bwrap accepts at most 9000 arguments (step 28).
- **Every secret needs two entries:** one for sandboxed commands (`sandbox.credentials`, `filesystem.denyRead`), one `Read(...)` deny rule for the file tools (step 21).
- **The permission mode is separate from the sandbox:** set `permissions.defaultMode` if the mode matters (step 19).
- **Stage explicit paths from inside the sandbox** (step 27).
- **`!` commands are not sandboxed**; probes must be run by Claude (step 19).
