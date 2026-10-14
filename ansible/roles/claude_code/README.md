# claude_code

Claude Code with its Bash sandbox on a Linux host. Lab 0f.

## What it does

- Installs the sandbox's dependencies from Ubuntu: `bubblewrap` and `socat` (`state: present`, so they keep receiving security updates).
- Adds Anthropic's signed apt repository (`stable` channel): the key in `/etc/apt/keyrings/claude-code.asc`, the source in `/etc/apt/sources.list.d/claude-code.sources`.
- Installs `claude-code` at the exact version `claude_code_version` (`defaults/main.yml`) and pins it with `/etc/apt/preferences.d/claude-code` (`Pin-Priority: 1001`), so `apt upgrade` does not move it.
- Copies `/usr/bin/bwrap` to `/usr/local/bin/claude-bwrap` and installs the AppArmor profile `/etc/apparmor.d/claude-bwrap`, which runs that copy unconfined with the `userns` permission; reloads it with `apparmor_parser -r` when it changes.
- Installs `/etc/claude-code/managed-settings.json` (root:root `0644`): the sandbox policy that user and repository settings cannot loosen. See "Managed settings" below.

Package installations of Claude Code do not update themselves; the version changes only through this role.

## Why a bwrap copy

Ubuntu 24.04 restricts unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`): without an exception, bwrap fails with `loopback: Failed RTM_NEWADDR: Operation not permitted`. A profile for `/usr/bin/bwrap` would lift the restriction for every program that runs the system bwrap. The copy keeps the exception to the one path that managed settings point Claude Code at (`sandbox.bwrapPath`, honoured only from managed settings, so a repository cannot redirect it). Same model as `lab0a-unshare` in `lab_tools`.

Caveat: the copy does **not** receive bubblewrap security updates by itself. Run the role after every bubblewrap upgrade; the `copy` task compares checksums and refreshes the copy.

## Managed settings

`files/managed-settings.json` is the highest settings level on the host. Every key in it wins over user (`~/.claude/settings.json`), project (`.claude/`) and `--settings` values; list keys are merged, and the `allowManaged…Only` locks stop lower levels from adding entries.

| Key | Why |
|---|---|
| `requiredMinimumVersion: "2.1.285"` | Claude Code refuses to start below it; from 2.1.285 a repository cannot loosen an admin-required sandbox |
| `env.DISABLE_UPDATES: "1"` | Blocks `claude update` and `claude install` (after switching from the native installer, `claude doctor` advises `claude install`, which would bring the self-updating build back) |
| `permissions.disableBypassPermissionsMode: "disable"` | No `--dangerously-skip-permissions` |
| `permissions.deny` `Read(...)` | Claude's file tools run outside the sandbox; these rules keep them away from the same secrets |
| `sandbox.enabled`, `failIfUnavailable`, `allowUnsandboxedCommands: false` | Sandbox on; refuse to start without it; no unsandboxed retry. `false` in managed settings makes the sandbox admin-required: repository settings that would loosen it are ignored |
| `sandbox.autoAllowBashIfSandboxed: true` | Sandboxed commands run without a prompt; the boundary is the sandbox |
| `sandbox.bwrapPath` | The bwrap copy with the AppArmor exception (managed-only key) |
| `sandbox.network.allowManagedDomainsOnly`, `strictAllowlist`, `allowedDomains` | Only these hosts, no prompts for others; user settings and saved approvals cannot widen the list |
| `sandbox.filesystem.allowManagedReadPathsOnly`, `denyRead` | No `.env` file under the home directory is readable; lower levels cannot re-open reads |
| `sandbox.credentials` | `~/.ssh`, `~/.aws` and Claude Code's own OAuth token file are unreadable; a session token variable is unset for sandboxed commands |

`~` resolves to the home directory of whoever runs `claude`, so the file contains no user name. The file must stay world-readable: Claude Code starts **without** a managed settings file it cannot read (it only reports it in `/status` and `claude doctor`).

## Check mode on a new host: `failed=1` is expected

The first `--check` on a host without the Claude Code repository ends with:

```
TASK [claude_code : Install Claude Code]
fatal: [<host>]: FAILED! => {"changed": false, "msg": "No package matching 'claude-code' is available"}
```

In check mode the tasks before it only report that they would add the key and the repository; nothing is written and the cache refresh does not run, so apt has never heard of `claude-code`. This is a limit of check mode for tasks that depend on earlier changes, not an error in the role. Run the role for real; from then on check mode works, including for upgrades (the new version is in the cache and the install task shows `changed`). Making the task tolerant in check mode (`ignore_errors` or `when: not ansible_check_mode`) was rejected: it would also hide real errors, such as a mistyped version during an upgrade.

## Upgrade Claude Code

1. See which versions the repository offers, and when each was released (prefer one that is at least a week or two old):

   ```bash
   curl -fsS https://downloads.claude.ai/claude-code/apt/stable/dists/stable/main/binary-amd64/Packages | grep '^Version:'
   curl -fsS https://registry.npmjs.org/@anthropic-ai/claude-code | python3 -I -c 'import json,sys; t=json.load(sys.stdin)["time"]; print(t["<x.y.z>"])'
   ```

2. Set `claude_code_version` in `defaults/main.yml` (Debian version, e.g. `2.1.287-1`).
3. From `ansible/`: `ansible-lint`, then `ansible-playbook site.yml --limit <host> --check --diff` (the pin file shows the version change), then the real run.
4. Restart running Claude Code sessions (`claude --continue` resumes the conversation) and check `claude --version`.

Downgrades work the same way: the pin priority above 1000 lets apt install an older version.

## Replace the repository signing key

Needed only when Anthropic rotates the key (`apt update` then reports `NO_PUBKEY` or an invalid signature for `downloads.claude.ai`). The current key is rsa4096, created 2026-03-30, with no expiry.

1. Download it to a scratch directory and print its fingerprint, without touching your own keyring:

   ```bash
   d=$(mktemp -d); curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$d/claude-code.asc"
   gpg --homedir "$d" --show-keys --with-fingerprint "$d/claude-code.asc"
   ```

2. Compare the fingerprint with the one published in the official documentation (code.claude.com/docs/en/setup, "Install with Linux package managers"). Do not trust a fingerprint from the same server as the key alone.
3. Replace `files/claude-code.asc`, commit, and run the role: the key task is `changed` and the handler refreshes the apt cache.
