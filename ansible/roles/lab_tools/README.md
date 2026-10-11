# lab_tools

Tools needed by the labs that require changes outside the repository.

## What it does

- Copies `/usr/bin/unshare` to `/usr/local/bin/lab0a-unshare`.
- Installs the AppArmor profile `/etc/apparmor.d/lab0a-unshare`, which runs that copy unconfined with the `userns` permission, and reloads it with `apparmor_parser -r`.

Result: an unprivileged user can create a user namespace with full capabilities inside it through `lab0a-unshare`, while Ubuntu 24.04's default restriction (`kernel.apparmor_restrict_unprivileged_userns`) stays in effect for every other binary.

## Why a copy and not a profile for /usr/bin/unshare

AppArmor profiles attach by path. A profile for `/usr/bin/unshare` would lift the restriction for every user and script that runs the system `unshare`, and it could conflict with a profile the distribution might ship for that path in the future (none exists on this host today). A separate binary under `/usr/local/bin` keeps the exception narrow and explicit: only code that calls `lab0a-unshare` gets it.

## Caveat: no security updates

The copy is not owned by any package, so it does **not** receive util-linux security updates. Re-run the role after every util-linux upgrade so the copy is refreshed (the `copy` task replaces it when the source changes). When the labs no longer need it, remove both `/usr/local/bin/lab0a-unshare` and `/etc/apparmor.d/lab0a-unshare` (unload the profile first with `sudo apparmor_parser -R /etc/apparmor.d/lab0a-unshare`).
