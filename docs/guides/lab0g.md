# Lab 0g — Ansible Fundamentals: Step-by-Step Guide

Status: complete. Last updated: 2026-10-13. Results on this hardware: `results/lab0g.md`.

## Overview

Every configuration change in this repo becomes an Ansible role, so Ansible gets its own lab. The lab installs Ansible reproducibly, explains the concepts as they are needed, and applies real roles to Z790 the way Ansible is meant to be used: from a separate **control node** (here a MacBook) over **SSH**, with an inventory that names hosts and nothing else. Adding a node later is one more line in the inventory.

**What we build and run:**

- `ansible/ansible.cfg`, `ansible/inventory/group_vars/all.yml`: the minimal configuration.
- The `lab_tools` role from Lab 0a (a dedicated `unshare` copy and its AppArmor profile), applied for the first time with Ansible: natural drift, a real run, idempotency, deliberate drift.
- A new `common` role: the persistent AppArmor sysctl from Lab 0a, enforced both on disk and in the running kernel.
- `ansible/site.yml`: one entry point for everything; ansible-lint on top.

**Success criteria** (from `docs/roadmap.md`):

- From the control node over SSH, `--check --diff` shows the natural drift → a real run fixes it → a second run gives `changed=0`.
- Deliberate drift is detected by check mode and corrected.
- The sysctl is in a role, and the `aa-exec` bypass stays closed while `lab0a-unshare` still works.
- Every concept used is explained here.

**Setup used:**

| Role | Machine | Ansible |
|---|---|---|
| Managed node | Z790, Ubuntu 24.04, Python 3.12 | nothing needed: sshd + Python 3.9+ |
| Control node | MacBook (Apple M1), macOS 15 | ansible-core 2.21.5 (pipx, Homebrew Python 3.12) |
| Optional second install | Z790 itself | ansible-core 2.21.5 (pipx), only for checks that need no connection |

## Working conventions

- **Where commands run.** Each step says: on the **control node** (laptop), on the **node** (Z790), or **both**. All Ansible commands run from the `ansible/` directory of the repo (see step 9).
- **What a command does.** Each step says whether it needs root on the node and whether it changes anything.
- **Check before change.** Every run that changes the node is preceded by the same run in check mode (`--check --diff`).
- **Syncing the repo.** The control node has its own clone (step 5). Git transfers commits, not working-tree changes: every change the control node needs is committed first, then `git pull` on the control node.
- **Placeholders.** `<repo>` is the checkout path, `<user>` the account on the node. Examples use SSH port 22.

---

# Part 1 — Preparation

## Step 1/26 — Choose the source and the version

**Why:** Ubuntu's archive, PyPI and pipx/uv all offer Ansible. Pick one source and an exact version before installing anything, so the lab can be repeated with the same result.

**Command** (node, read-only):

```bash
apt-cache policy ansible ansible-core pipx | grep -E '^[a-z]|Installed|Candidate'
python3 --version
curl -fsS https://pypi.org/pypi/ansible-core/json | python3 -I -c 'import json,sys; i=json.load(sys.stdin)["info"]; print(i["version"], i["requires_python"])'
```

**Expected:** apt's candidates, the system Python, and PyPI's latest ansible-core with its Python requirement.

**Result (2026-10-12):** apt (Ubuntu 24.04) ships ansible-core 2.16.3 and the `ansible` bundle 9.2.0; PyPI's latest is **2.21.5**, `requires_python >=3.12`; the node has Python 3.12.3.

**Decision:**

- **`ansible-core==2.21.5` from PyPI, installed with pipx.** apt's 2.16.3 is from early 2024 and only receives security patches; current documentation describes 2.21. pipx installs a Python application into its own virtualenv, so neither the system Python nor apt packages are touched.
- **Only `ansible-core`, not the `ansible` bundle:** the bundle adds hundreds of community collections; the roles here use only `ansible.builtin`.
- **Pinned version:** `==2.21.5`. The dependencies are not pinned by this; their exact versions are recorded with `freeze` (steps 3 and 4).

## Step 2/26 — SSH access from the control node

**Why:** Ansible has no agent on the node; it connects with the control node's OpenSSH and honours `~/.ssh/config`. Everything needed to reach the node (address, user, port, key) goes there, so the inventory holds only the name `z790` and `ssh z790` behaves exactly like Ansible's connection. It also keeps addresses out of the repo.

**Command** (control node). Without a key on the server yet:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_lab -C "laptop-lab"
ssh-copy-id -i ~/.ssh/id_ed25519_lab.pub -p 22 <user>@z790
```

Then the host entry in `~/.ssh/config` (`HostName` resolves through `/etc/hosts` here; use an address otherwise; change `Port` if sshd listens elsewhere):

```
Host z790
  HostName z790
  User <user>
  Port 22
  IdentityFile ~/.ssh/id_ed25519_lab
  IdentitiesOnly yes
```

- `IdentityFile` names the key explicitly instead of relying on whatever ssh-agent happens to hold. `IdentitiesOnly yes` offers only that key (agent keys that match it still work, so no extra passphrase prompts).
- For each parameter SSH takes the **first** value from any matching `Host` block, top to bottom. Put specific hosts before groups and `Host *` last, so a specific entry can override a shared value.

Verify what SSH resolved (`-G` does not connect), then connect without any prompt, the way Ansible will (`BatchMode=yes` fails instead of asking for a password):

```bash
ssh -G z790 | grep -E '^(hostname|user|port|identityfile|identitiesonly) '
ssh -o BatchMode=yes -o ConnectTimeout=5 z790 'hostname; command -v python3; python3 --version'
```

**Expected:** exactly one `identityfile` line, the configured user and port; then `z790`, `/usr/bin/python3`, `Python 3.12.3`.

**Result:** as expected. Without a `Host` entry, `ssh -G` shows the defaults (local username, port 22, a list of default identity files).

## Step 3/26 — Install Ansible on the control node (macOS)

**Why:** the control node runs `ansible-playbook`. macOS ships Python 3.9 (`/usr/bin/python3`), too old for ansible-core 2.21 (needs >= 3.12). Homebrew's `pipx` runs on its own Python (3.15 at the time of writing), which ansible-core 2.21.5 does not list as supported (classifiers: 3.12–3.14). So Ansible's virtualenv gets an explicit Python: 3.12, the same minor version as the node.

**Command** (control node; installs software):

```bash
brew install python@3.12 pipx
pipx install --python /opt/homebrew/bin/python3.12 'ansible-core==2.21.5'
pipx ensurepath          # adds ~/.local/bin to PATH; open a new terminal afterwards
ansible --version
pipx runpip ansible-core freeze
```

**Expected:** `installed package ansible-core 2.21.5, installed using Python 3.12.x` and ten commands (`ansible`, `ansible-playbook`, `ansible-inventory`, …); then `ansible [core 2.21.5]`, `config file = None` (no `ansible.cfg` found from the current directory), Jinja 3.1.6, PyYAML 6.0.3; a freeze of nine packages.

**Result:** as expected, with Python 3.12.15. On macOS pipx keeps virtualenvs under `~/Library/Application Support/pipx`; the commands go to `~/.local/bin`.

- If `uv` is installed, pipx uses it instead of pip (`Using Python … environment at: .`, lower-case package names). Same packages, different installer.
- The virtualenv is tied to that Homebrew Python. If a later `brew upgrade` of `python@3.12` breaks `ansible`, run `pipx reinstall ansible-core`.

## Step 4/26 — Optional: Ansible on the node for connection-free checks

**Why:** syntax checks, inventory and config inspection and linting need no connection. Having Ansible on the server as well lets those checks run where the repo is edited, before anything is pushed to the control node. Real runs still go from the control node.

**Command** (node; installs software in `$HOME`):

```bash
sudo apt install pipx          # if not installed
pipx install 'ansible-core==2.21.5'
ansible --version
pipx runpip ansible-core freeze
```

**Expected:** `installed using Python 3.12.3`; `ansible [core 2.21.5]`; the same nine packages as on the control node.

**Result:** the two freezes are identical package for package (`results/lab0g.md`). The first Ansible run creates `~/.ansible/` (local temp files).

## Step 5/26 — The repo on the control node

**Why:** `ansible-playbook` reads playbooks, roles and the inventory from the control node's own disk, so the control node needs a checkout.

**Command** (control node):

```bash
git clone z790:ai-homelab ~/projects/ai-homelab
```

- Cloned from the node over SSH (`host:path`, path relative to the remote user's home), using the same SSH entry as Ansible. Unpushed commits reach the control node without going through the public GitHub repo.
- Cloning from GitHub works the same; then every change has to be pushed before the control node can use it.

**Expected / Result:** a normal clone; `git log` shows the node's latest commit.

---

# Part 2 — Understanding

## Step 6/26 — Concepts

**Why:** Ansible's output only makes sense with a handful of ideas in mind. Each of them shows up in a later step.

- **Desired state, not steps.** A script says "copy this file". An Ansible task says what must be true: the file exists, with this content, owner and mode. The module checks first and changes only what differs. Every task ends as `ok` (already right), `changed` (was different, fixed), `failed` or `skipped`.
- **Idempotency.** One run or ten give the same end state; a second run must report `changed=0`. Modules like `copy` are idempotent by design; `command` and `shell` run arbitrary commands, cannot know what they changed, and report `changed` by default.
- **Agentless.** For each task the control node packages the module (Python code) with its arguments, sends it to the node (over SSH), runs it there with the node's Python (via `sudo` with `become`), reads back the JSON result and deletes the temporary files. The node needs only sshd and Python 3.9+.
- **Inventory:** the hosts, their groups and variables. **Playbook:** a list of plays; a play maps hosts to roles or tasks and sets options such as `become`. Every play starts with *Gathering Facts* (the `setup` module), which counts as one `ok`. **Role:** a directory with a fixed layout (`tasks/`, `handlers/`, `files/`, …), found in `roles/` next to the playbook.
- **FQCN:** `ansible.builtin.copy` is the module's full name (collection + module), so a module with the same short name from another collection can never be picked by mistake.
- **Handlers** run only if a task that `notify`s them reported `changed`; once, at the end of the play; matched by name. Typical use: reload a service only when its configuration changed.
- **Check mode** (`--check`) runs every check without applying changes; `--diff` shows what would change in file contents. Limits: `command` cannot predict an arbitrary command, so in check mode it reports `skipped` (unless `creates`/`removes` is set, step 21), and `changed_when` is not evaluated for skipped results (`modules/command.py`, `executor/task_executor.py` in 2.21.5). With `become`, checks still run as root.

## Step 7/26 — Review `ansible/` line by line

**Why:** know exactly what will run before it runs.

**Command** (either machine, read-only, from the repo root):

```bash
for f in $(find ansible -type f | sort); do echo "=== $f ($(stat -c '%a %s' "$f"))"; cat -A "$f"; done
git ls-files -s ansible
```

- `cat -A` shows invisible characters (`$` at line ends, `^I` tabs, `^M` CRLF). Whitespace matters here: the AppArmor profile on the host differs from the repo only in indentation.
- Git stores only the executable bit (`100644`/`100755`), not group-write; a working tree with umask 002 shows `664`. That is why every `copy` task sets `mode` explicitly: without it, `copy` uses the target's umask for a new file and keeps whatever mode an existing file has.

**`lab0a.yml`:**

```yaml
- name: Lab 0a tools     # a play; shown as PLAY [Lab 0a tools]
  hosts: z790            # which inventory hosts it applies to
  become: true           # every task runs as root through sudo
  roles:
    - lab_tools          # ansible/roles/lab_tools/
```

**`roles/lab_tools/tasks/main.yml`:**

- *Copy unshare to a dedicated binary*: `copy` with `remote_src: true` copies the **node's own** `/usr/bin/unshare` to `/usr/local/bin/lab0a-unshare`, root:root `0755`. It compares checksums, replaces atomically (temp file + rename) and then fixes owner, group and mode.
- *Install AppArmor profile*: `copy` of `roles/lab_tools/files/lab0a-unshare` (relative `src` is looked up in the role's `files/` on the control node) to `/etc/apparmor.d/`, root:root `0644`, `notify: Reload lab0a-unshare AppArmor profile`.

**`roles/lab_tools/handlers/main.yml`:** `command: apparmor_parser -r /etc/apparmor.d/lab0a-unshare` loads the profile into the kernel; writing the file alone changes nothing until the kernel reads it. `changed_when: true` states the intent (and satisfies ansible-lint); `command` reports `changed` anyway.

**Expected on a host where Lab 0a was applied by hand:** the binary is identical (`ok`), the profile differs in indentation (`changed`). On a fresh host both tasks are `changed` and the handler runs.

---

# Part 3 — Configuration

## Step 8/26 — How Ansible reaches the node (decision)

**Why:** the inventory says nothing about the connection; Ansible's default transport is `ssh` (`DEFAULT_TRANSPORT` in `config/base.yml`).

**Options considered:**

- `ansible_connection: local` (or `-c local`) for a node that is also the control node: no SSH at all. It hides exactly what Ansible does in real use: SSH authentication and host keys, become over an SSH session, interpreter discovery on another machine.
- `transport = local` in `ansible.cfg`: global; every host's tasks would run on the control node while Ansible believes it manages another machine. Dangerous.
- **SSH with an inventory that holds only names (chosen):** connection details in the control node's `~/.ssh/config` (step 2). The same playbooks run unchanged from any control node, and a new node is one more line in the inventory.

## Step 9/26 — `ansible.cfg`

**Why:** without configuration every command needs `-i inventory/hosts.yml`; forgetting it makes Ansible fall back to `/etc/ansible/hosts`, which does not exist.

**File** `ansible/ansible.cfg` (already in the repo):

```ini
# Read only when Ansible runs from this directory (or via ANSIBLE_CONFIG).
[defaults]
inventory = inventory/hosts.yml
```

- Lookup order, first found wins (`config/manager.py`): `$ANSIBLE_CONFIG`, `./ansible.cfg` in the **current directory** (ignored if that directory is world-writable), `~/.ansible.cfg`, `/etc/ansible/ansible.cfg`. Hence: all Ansible commands run from `ansible/`.
- A relative `inventory` path resolves against the config file's directory, not the current one (`expand_relative_paths` in `config/base.yml`).
- One config for the whole `ansible/` directory, not one per lab: inventory and roles are shared; only playbooks are per lab.
- Nothing else, in particular no `host_key_checking = False` or other switches that disable a safety check.

## Step 10/26 — Which settings are in effect

**Why:** Ansible has hundreds of settings. `dump --only-changed` lists only those that differ from the defaults, each with its source: the answer to "where did Ansible get this value?".

**Command** (both, read-only):

```bash
cd <repo>/ansible && ansible-config dump --only-changed
```

**Expected / Result:**

```
CONFIG_FILE() = <repo>/ansible/ansible.cfg
DEFAULT_HOST_LIST(<repo>/ansible/ansible.cfg) = ['<repo>/ansible/inventory/hosts.yml']

GALAXY_SERVERS:
```

- `DEFAULT_HOST_LIST` is the internal name of `inventory`; the source is in parentheses (a file, or `env: ANSIBLE_…`); the path is now absolute.
- `GALAXY_SERVERS:` is always printed (the servers `ansible-galaxy` downloads from); empty here.
- From the repo root the same command prints `CONFIG_FILE() = None` and no `DEFAULT_HOST_LIST`.
- In a terminal `ansible-config` opens a pager (`less`, quit with `q`); `ANSIBLE_PAGER=cat` prints directly.

## Step 11/26 — Syntax and inventory, without a connection

**Why:** catch YAML, module-name and structure errors, and see the inventory exactly as Ansible sees it, before anything connects to a node.

**Command** (both, read-only, from `ansible/`):

```bash
ansible-playbook site.yml --syntax-check
ansible-inventory --graph
ansible-inventory --host z790
```

**Expected:** `playbook: site.yml`; a tree with `@all` → `@ungrouped` → the inventory's hosts (`@` marks a group; `ungrouped` collects hosts in no other group); and the variables of `z790`.

**Result:** as expected. `--host z790` shows only `{"ansible_python_interpreter": "/usr/bin/python3"}` (from `group_vars/all.yml`, step 12): no `ansible_connection`, `ansible_host`, `ansible_port` or `ansible_user`. SSH is the default transport and OpenSSH supplies the rest.

---

# Part 4 — Connecting

## Step 12/26 — First contact: `ping`, and a pinned interpreter

**Why:** the first command that reaches the node. The `ping` module is not ICMP: it tests the whole chain (SSH with the configured key, copying the module to a temp directory on the node, finding Python, running it, JSON back). If `ping` returns `pong`, every later task has a working transport.

**Command** (control node, from `ansible/`; no root, changes nothing):

```bash
ansible z790 -m ansible.builtin.ping
```

`z790` is the host pattern and `-m` the module: an *ad-hoc* command, one module without a playbook.

**Expected / Result:**

```
z790 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

**Why `group_vars/all.yml` pins the interpreter.** Without it, the first ping printed a warning and `"discovered_interpreter_python": "/usr/bin/python3.12"`. The default `interpreter_python = auto` walks a fixed list (`python3.14`, `python3.13`, `python3.12`, … and only then `/usr/bin/python3`) and warns whenever it lands on that list. A newer `python3.X` installed later would silently become Ansible's interpreter, and modules that rely on distro Python packages would break (`ansible.builtin.apt` needs `python3-apt`, built only for the system Python). So `ansible/inventory/group_vars/all.yml` (loaded automatically next to the inventory file) pins it for every managed host:

```yaml
---
# Ubuntu's system Python; distro modules such as python3-apt are built only for it.
# Without this, discovery picks the newest python3.X found on the host.
ansible_python_interpreter: /usr/bin/python3
```

A host with another OS overrides it in its own `host_vars`. The interpreter is a property of the managed hosts, so it lives in the inventory, not in `ansible.cfg`.

## Step 13/26 — Become over SSH

**Why:** the playbooks use `become: true`. Testing escalation alone, with a harmless command, separates privilege problems (sudo asking for a password without a TTY, wrong user) from playbook problems.

**Command** (control node; root on the node, changes nothing):

```bash
ansible z790 -m ansible.builtin.command -a id --become
```

Ansible wraps the module in `sudo -u root /bin/sh -c '… /usr/bin/python3 <module>'` on the node and waits for a success marker. If sudo asks for a password, add `-K` (`--ask-become-pass`): Ansible asks once locally and passes it to sudo.

**Expected / Result:**

```
z790 | CHANGED | rc=0 >>
uid=0(root) gid=0(root) groups=0(root)
```

`CHANGED` although `id` changes nothing: `command` cannot know what an arbitrary command did (step 6).

---

# Part 5 — The `lab_tools` role

## Step 14/26 — Dry run: the natural drift

**Why:** the first run of a role should change nothing and show what it *would* change. On Z790 the role's files were installed by hand in Lab 0a; the profile on the host is indented, the repo's is not. The repo is the source of truth, so Ansible must report that difference.

**Command** (control node; root on the node, changes nothing):

```bash
ansible-playbook lab0a.yml --check --diff
```

**Expected / Result:**

```
TASK [Gathering Facts] *****
ok: [z790]

TASK [lab_tools : Copy unshare to a dedicated binary for Lab 0a] *****
ok: [z790]

TASK [lab_tools : Install AppArmor profile that allows user namespaces for the copy] *****
--- before: /etc/apparmor.d/lab0a-unshare
+++ after: <repo>/ansible/roles/lab_tools/files/lab0a-unshare
@@ -2,5 +2,5 @@
 include <tunables/global>

 profile lab0a-unshare /usr/local/bin/lab0a-unshare flags=(unconfined) {
-  userns,
+userns,
 }

changed: [z790]

RUNNING HANDLER [lab_tools : Reload lab0a-unshare AppArmor profile] *****
skipping: [z790]

PLAY RECAP *****
z790 : ok=3 changed=1 unreachable=0 failed=0 skipped=1 rescued=0 ignored=0
```

- `before` is the file on the node, `after` the file from the repo on the control node.
- The handler is notified and starts, but `command` does not run `apparmor_parser` in check mode: `skipping`.
- `ok=3` counts Gathering Facts and the changed task: `changed` is a subset of `ok`.
- On the node nothing changed: same mtime, same indented 126-byte profile.

## Step 15/26 — Real run

**Why:** apply the one difference check mode showed. The handler reloads the profile; without the reload, the file on disk and the profile in the kernel would differ until the next reboot.

**Command** (control node; **changes the node** as root):

```bash
ansible-playbook lab0a.yml --diff
```

**Expected / Result:** the same diff, the profile task `changed`, and this time `RUNNING HANDLER … changed: [z790]`. Recap `ok=4 changed=2 skipped=0`.

Verify on the node (read-only):

```bash
stat -c '%y %U:%G %a %s %n' /etc/apparmor.d/lab0a-unshare /usr/local/bin/lab0a-unshare
cmp /etc/apparmor.d/lab0a-unshare <repo>/ansible/roles/lab_tools/files/lab0a-unshare && echo same
cat /sys/kernel/security/apparmor/policy/profiles/lab0a-unshare.0/mode
```

The profile is byte-for-byte the repo file (124 bytes, new mtime); the binary is untouched; the loaded profile's mode is `unconfined`.

Ansible compares file **text**, not meaning: a whitespace-only change is `changed` and fires the handler, although the compiled AppArmor policy is identical (its securityfs entries still carry the boot time).

## Step 16/26 — Functional test

**Why:** Ansible reports state; the point of the role is an effect. An unprivileged user must get a user namespace with root inside through `lab0a-unshare`, while Ubuntu's restriction stays in place for every other binary.

**Command** (node, as an unprivileged user, no sudo):

```bash
lab0a-unshare --user --map-root-user id
unshare --user --map-root-user id
```

**Expected / Result:**

```
uid=0(root) gid=0(root) groups=0(root),65534(nogroup)
unshare: write failed /proc/self/uid_map: Operation not permitted
```

Host groups with no mapping inside the namespace appear as `nogroup`.

## Step 17/26 — Second run: idempotency

**Why:** Ansible's core promise. With the node already in the desired state, a run must change nothing and say so.

**Command** (control node):

```bash
ansible-playbook lab0a.yml --diff
```

**Expected / Result:** every task `ok`, recap `ok=3 changed=0`. No diff (printed only for changes) and no `RUNNING HANDLER` line: nothing notified the handler, so it does not even start. A task that is `changed` on every run means a badly written role or something outside changing the system.

## Step 18/26 — Deliberate drift

**Why:** see how the role reacts when someone changes by hand what it manages. Group-write on the binary is chosen on purpose: it is the bit git does not keep (the reason for the explicit `mode`), and it is dangerous here: a binary that AppArmor lets create user namespaces, writable by its group, can be replaced by any group member, and the replacement inherits the exception.

**Command** (node; root, **changes the node**):

```bash
sudo chmod 0775 /usr/local/bin/lab0a-unshare && ls -l /usr/local/bin/lab0a-unshare
```

**Expected / Result:** `-rwxrwxr-x 1 root root 43624 … /usr/local/bin/lab0a-unshare`. Content, owner and mtime are unchanged (`chmod` changes ctime; `ls -l` shows mtime).

## Step 19/26 — Check mode detects the drift

**Why:** check mode as an audit: it tells you that someone touched the node, without changing anything.

**Command** (control node; root on the node, changes nothing):

```bash
ansible-playbook lab0a.yml --check --diff
```

**Expected / Result:** the binary task `changed`, the profile task `ok`, no handler (the binary task notifies nothing; AppArmor does not care about the binary's mode). Recap `ok=3 changed=1`.

**No diff for the mode.** `copy`'s diff covers file content only (`modules/copy.py` calls `set_fs_attributes_if_different` without a diff). A `copy` task that is `changed` without a diff means owner, group or mode differ: check with `ls -l` on the node, or run with `-v` to see the task's full result.

## Step 20/26 — Fix the drift

**Why:** close the loop: detect → fix → confirm.

**Command** (control node; **changes the node**, then confirms):

```bash
ansible-playbook lab0a.yml --diff
ansible-playbook lab0a.yml --diff
```

**Expected / Result:** the first run's output is identical to the check-mode run (`ok=3 changed=1`, no diff, no handler): check mode predicted it exactly. The second run: `ok=3 changed=0`.

On the node the mode is `0755` again; ctime is new while mtime is unchanged: Ansible fixed only the attributes and did not rewrite the file, because the checksums match.

---

# Part 6 — The `common` role

## Step 21/26 — The persistent sysctl becomes a role

**Why:** Lab 0a enabled `kernel.apparmor_restrict_unprivileged_unconfined = 1` by hand in `/etc/sysctl.d/60-apparmor-restrict-unconfined.conf`. It closes the 2025 Qualys bypass (`aa-exec` into a permissive profile to get a user namespace with capabilities). Configuration changes belong in roles.

**Decisions:**

- **A separate role, `common`, not a task in `lab_tools`.** `lab_tools` is meant to be removed when the labs no longer need it; this setting protects the host on its own and must stay. `common` is the baseline role for every host.
- **Byte-for-byte.** The role's file is copied from the host and compared with `cmp` and `cat -A` (one line, LF at the end, 53 bytes), so the first run is `ok`, not `changed`.
- **The file and the running value.** Only `ansible.builtin` is used, so there is no `sysctl` module. A file in `/etc/sysctl.d/` acts only at boot. A handler on file change would not catch `sysctl -w …=0` at runtime: the file stays right, Ansible says `ok`, the protection is off until reboot. The role therefore reads the running value and loads the file when it differs.

**File** `ansible/roles/common/tasks/main.yml` (already in the repo):

```yaml
---
- name: Install sysctl drop-in that restricts unprivileged unconfined profiles
  ansible.builtin.copy:
    src: 60-apparmor-restrict-unconfined.conf
    dest: /etc/sysctl.d/60-apparmor-restrict-unconfined.conf
    owner: root
    group: root
    mode: "0644"

- name: Read the running value of kernel.apparmor_restrict_unprivileged_unconfined
  ansible.builtin.command: sysctl -n kernel.apparmor_restrict_unprivileged_unconfined
  register: common_restrict_unconfined
  changed_when: false
  check_mode: false

- name: Apply the drop-in when the running value differs
  ansible.builtin.command:
    cmd: sysctl -p /etc/sysctl.d/60-apparmor-restrict-unconfined.conf
    # With removes, check mode reports "would run" as changed instead of skipping.
    removes: /etc/sysctl.d/60-apparmor-restrict-unconfined.conf
  when: common_restrict_unconfined.stdout != "1"
```

- `register` stores a task's result in a variable; the `common_` prefix follows the convention that role variables start with the role's name.
- `changed_when: false`: reading is never a change. `check_mode: false`: the read runs in check mode too (it only reads); otherwise `when` would have nothing to compare.
- `when` loads the file only when the kernel's value differs. `sysctl -p FILE` loads that file (with `-p`, sysctl's arguments are files).
- In check mode `command` reports `skipping` whether it would run or not, unless `creates`/`removes` is set; with `removes` pointing at an existing file it reports `changed` (`modules/command.py`). That makes runtime drift visible in check mode (step 23).

**Playbooks:**

```yaml
# common.yml: the baseline for every host
- name: Common baseline
  hosts: all
  become: true
  roles:
    - common
```

```yaml
# site.yml: the entry point for everything
- name: Common baseline
  ansible.builtin.import_playbook: common.yml

- name: Lab 0a tools
  ansible.builtin.import_playbook: lab0a.yml
```

`site.yml` is Ansible's conventional name for the playbook that brings "the whole site" to the desired state; it only imports. `ansible-playbook site.yml` runs everything; `common.yml` or `lab0a.yml` run one part.

## Step 22/26 — First run of `site.yml`

**Why:** the new role meets the hand-made state. Prediction: nothing changes (same file, value already `1`).

**Command** (control node; root on the node):

```bash
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
```

`--limit z790` restricts the run to Z790: `common.yml` targets `all`, and other hosts in the inventory are not part of this lab.

**Expected / Result** (both runs identical):

```
PLAY [Common baseline]
TASK [Gathering Facts]                                            ok: [z790]
TASK [common : Install sysctl drop-in …]                          ok: [z790]
TASK [common : Read the running value of kernel.apparmor_…]       ok: [z790]
TASK [common : Apply the drop-in when the running value differs]  skipping: [z790]
PLAY [Lab 0a tools]
TASK [Gathering Facts]                                            ok: [z790]
TASK [lab_tools : Copy unshare to a dedicated binary for Lab 0a]  ok: [z790]
TASK [lab_tools : Install AppArmor profile …]                     ok: [z790]
PLAY RECAP
z790 : ok=6 changed=0 unreachable=0 failed=0 skipped=1 rescued=0 ignored=0
```

Each play gathers facts again by default. The apply task is skipped by `when` (value already `1`) before the module runs. The role adopted the hand-made state without a single change.

## Step 23/26 — Runtime drift

**Why:** test the "file + running value" design: the value changes in the kernel while the file stays correct. While the value is `0` the `aa-exec` bypass is open again, so keep the window short.

**Command:**

```bash
# node (root): kernel 0, file still 1
sudo sysctl -w kernel.apparmor_restrict_unprivileged_unconfined=0 && cat /etc/sysctl.d/60-apparmor-restrict-unconfined.conf
# control node
ansible-playbook site.yml --limit z790 --check --diff
ansible-playbook site.yml --limit z790 --diff
ansible-playbook site.yml --limit z790 --diff
# node: check the running value, not the file
sysctl kernel.apparmor_restrict_unprivileged_unconfined
```

**Expected / Result:**

- Check mode: the file `ok`, the read `ok`, **the apply task `changed`** (not `skipping`, thanks to `removes`); recap `ok=7 changed=1`. The kernel is still `0`.
- Real run: the same output; `sysctl -p` loads the file and the kernel is back to `1`.
- Next run: `ok=6 changed=0 skipped=1`.

## Step 24/26 — The bypass stays closed, the exception still works

**Why:** the functional criterion for the sysctl. Both AppArmor settings must coexist: the explicit exception works, the detour through a foreign profile does not.

**Command** (node, as an unprivileged user):

```bash
aa-exec -p trinity -- unshare --user --map-root-user id -u
lab0a-unshare --user --map-root-user sh -c 'id -u; grep CapEff /proc/self/status'
```

**Expected / Result:**

```
unshare: write failed /proc/self/uid_map: Operation not permitted
0
CapEff:	000001ffffffffff
```

---

# Part 7 — ansible-lint

## Step 25/26 — Install ansible-lint

**Why:** ansible-lint is a static analyser: it reads playbooks and roles without connecting anywhere and flags errors, risky practices and convention breaks. Started while the roles are small, every later role starts from a clean baseline.

**Version:** 26.9.0 (2026-09-22). On 2026-10-13, 26.10.1 had been released that day and 26.10.0 the day before; the older release had three weeks to show problems. It requires `ansible-core>=2.16.19, !=2.17.*`, `cryptography>=50.0.0`, `packaging>=22.0`, `pyyaml>=6.0.1`: all already satisfied.

**Command** (both; installs software in `$HOME`):

```bash
pipx inject ansible-core 'ansible-lint==26.9.0' --include-apps && ansible-lint --version
pipx runpip ansible-core freeze
```

- `pipx inject` installs into the **existing** ansible-core virtualenv. A separate `pipx install ansible-lint` would pull its own, newest ansible-core and lint against a different Ansible than the one running the playbooks.
- `--include-apps` puts the `ansible-lint` command into `~/.local/bin`.

**Expected / Result:** `ansible-lint 26.9.0 using ansible-core:2.21.5 ansible-compat:26.10.0 ruamel-yaml:0.19.1`. The inject added 21 packages (ansible-compat, black, yamllint, ruamel-yaml, jsonschema, …); the freeze shows ansible-core's nine packages unchanged. ansible-lint may announce a newer release; the pin stays.

## Step 26/26 — Run ansible-lint

**Why:** check everything under `ansible/` against the rules.

**Command** (both, read-only, from `ansible/`):

```bash
ansible-lint
ansible-lint -v
```

**Expected / Result:**

```
Passed: 0 failure(s), 0 warning(s) in 10 files processed of 16 encountered. Last profile that met the validation criteria was 'production'.
```

- Profiles (`min`, `basic`, `moderate`, `safety`, `shared`, `production`) are strictness levels; `production` is the strictest.
- A clean result only counts if lint looked at the right files: `-v` shows syntax checks of `common.yml`, `lab0a.yml`, `site.yml`, `roles/common` and `roles/lab_tools`.
- lint takes the repo root (the `.git` directory) as project root and creates its cache in `<repo>/.ansible/`. Git does not see empty directories, but anything lint installs there later would show up as untracked files, so `.gitignore` has:

```gitignore
# ansible-lint cache, created at the project root
.ansible/
```

---

## Gotchas

- **Run from `ansible/`.** `ansible.cfg` is read only from the current directory; elsewhere there is no inventory and Ansible does not know `z790`.
- **Pin the interpreter.** Discovery prefers the newest `python3.X`, not the system Python (step 12).
- **`copy` diffs content only.** `changed` without a diff means owner, group or mode (step 19).
- **`command` in check mode** reports `skipped` unless `creates`/`removes` is set (steps 6, 21).
- **Text, not meaning.** A whitespace-only change is `changed` and fires handlers (step 15).
- **Check the running value, not the file,** for sysctls (step 23).
- **`ansible-config` and `ansible-doc` use a pager** in a terminal; `ANSIBLE_PAGER=cat` disables it.
