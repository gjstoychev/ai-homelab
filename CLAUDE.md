# Rules for future sessions

- All repository content (docs, code comments, commit messages) must be in English, even when the conversation is in another language.
- Each lab gets `results/<lab>.md` following `results/TEMPLATE.md`. Mistakes and dead ends are recorded, not omitted.
- Commands that proved useful go into `docs/runbook.md` under a heading for the lab.
- Configuration changes become Ansible roles under `ansible/roles/`, not ad-hoc notes.
- Never commit secrets, IP addresses of the home network, or credentials.
- `work/` holds disposable lab working files (rootfs, downloads, scratch). It is gitignored and everything in it must be recreatable from scripts; never store models or anything expensive to rebuild there.
- `docs/roadmap.md` is the source of truth for lab order, scope and status. Update it when a lab starts, changes scope or finishes.
- Each lab also gets `docs/guides/<lab>.md`: the step-by-step procedure with commands and the reasoning behind them (how to repeat the lab), separate from `results/<lab>.md` (what happened on this hardware).

# Claude Code on z790 (Lab 0f)

- Shell commands run in Claude Code's sandbox (managed settings in `/etc/claude-code/`, role `claude_code`): the home directory is read-only, the network goes only to the allowlisted hosts, and there is no SSH, no Ollama on localhost and no GPU. If a command hits the sandbox, report the restriction; do not look for a way around it.
- `git add` and `git commit` are pre-approved in `.claude/settings.json` (the diff and the exclusion check are still shown, and nothing is committed before the user approves in the conversation); `git push` is the user's. Stage explicit paths (`git add <file> …`). Never `git add -A` or `git add .` from a sandboxed command: the sandbox's placeholders for protected paths (`.bashrc`, `.gitconfig`, `.mcp.json`, …) appear as untracked files inside it.
- Claude writes Ansible; the user runs it from the control node. Connection-free checks (`--syntax-check`, `ansible-lint`) work in the sandbox; `ANSIBLE_LOCAL_TEMP` comes from `.claude/settings.json`.
- `ansible/roles/claude_code/files/{managed-settings.json,claude-bwrap}` define the sandbox and take effect when the role runs. Call out every change to them explicitly when asking for approval.
- Do not ask to read `/proc/<pid>/environ` with the file tools (they run outside the sandbox; process environments hold tokens).
- Do not add permission deny rules with globs over large trees (such as `/proc`): they are merged into the sandbox and expanded at every command, and bwrap accepts at most 9000 arguments.
- Claude's memory and settings under `~/.claude` are writable only with the file tools (Edit/Write), not from Bash.
