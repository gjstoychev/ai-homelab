# common

Baseline state for every managed host, independent of any lab.

## What it does

- Installs `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf` with `kernel.apparmor_restrict_unprivileged_unconfined = 1`.
- Reads the running value and loads the file with `sysctl -p` when it differs, so the setting holds now and not only after the next boot.

Result: an unprivileged process can no longer use `aa-exec` to switch into a permissive AppArmor profile and create a user namespace with full capabilities (the 2025 Qualys bypass of Ubuntu's userns restriction).

## Why a separate role

`lab_tools` is removed when the labs no longer need it; this setting protects the host on its own and must stay.

## Check mode

The read task runs in check mode too (`check_mode: false`; it only reads). The apply task uses `removes:` so that check mode reports a differing running value as `changed` instead of `skipping`.
