# claude_code

Claude Code with its Bash sandbox on a Linux host. Lab 0f.

## What it does

- Installs the sandbox's dependencies from Ubuntu: `bubblewrap` and `socat` (`state: present`, so they keep receiving security updates).
- Adds Anthropic's signed apt repository (`stable` channel): the key in `/etc/apt/keyrings/claude-code.asc`, the source in `/etc/apt/sources.list.d/claude-code.sources`.
- Installs `claude-code` at the exact version `claude_code_version` (`defaults/main.yml`) and pins it with `/etc/apt/preferences.d/claude-code` (`Pin-Priority: 1001`), so `apt upgrade` does not move it.

Package installations of Claude Code do not update themselves; the version changes only through this role.

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
