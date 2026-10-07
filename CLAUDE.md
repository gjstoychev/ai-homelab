# Rules for future sessions

- All repository content (docs, code comments, commit messages) must be in English, even when the conversation is in another language.
- Each lab gets `results/<lab>.md` following `results/TEMPLATE.md`. Mistakes and dead ends are recorded, not omitted.
- Commands that proved useful go into `docs/runbook.md` under a heading for the lab.
- Configuration changes become Ansible roles under `ansible/roles/`, not ad-hoc notes.
- Never commit secrets, IP addresses of the home network, or credentials.
- `work/` holds disposable lab working files (rootfs, downloads, scratch). It is gitignored and everything in it must be recreatable from scripts; never store models or anything expensive to rebuild there.
- `work/` holds disposable lab working files (rootfs, downloads, scratch). It is gitignored and everything in it must be recreatable from scripts; never store models or anything expensive to rebuild there.
- Each lab also gets `docs/guides/<lab>.md`: the step-by-step procedure with commands and the reasoning behind them (how to repeat the lab), separate from `results/<lab>.md` (what happened on this hardware).
