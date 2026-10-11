#!/usr/bin/env bash
# minicontainer.sh - a minimal container built from Linux primitives (Lab 0a).
# Namespaces (uts, pid, mount, ipc, cgroup, net), cgroups v2 limits,
# pivot_root into an Alpine rootfs, and a veth pair to the host.
# Usage: sudo scripts/minicontainer.sh [command ...]   (default: interactive /bin/sh)
set -euo pipefail

NAME="${NAME:-lab0a}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="${ROOTFS:-$REPO/work/lab0a/rootfs}"
CG="/sys/fs/cgroup/$NAME"
MEM_MAX="${MEM_MAX:-100M}"
PIDS_MAX="${PIDS_MAX:-20}"
CPU_MAX="${CPU_MAX:-50000 100000}"   # quota and period in microseconds: half a core
HOST_IP="${HOST_IP:-10.200.0.1/24}"
CONT_IP="${CONT_IP:-10.200.0.2/24}"

die() { echo "minicontainer: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"
[ -f "$ROOTFS/bin/busybox" ] || die "no Alpine rootfs at $ROOTFS"   # not bin/sh: its absolute symlink would resolve on the host
[ ! -e "$CG" ] || die "cgroup $CG already exists (running or stale)"
[ ! -e "/run/netns/$NAME" ] || die "netns $NAME already exists (running or stale)"

cleanup() {
  # Deleting the netns also destroys the veth pair (both ends).
  ip netns del "$NAME" 2>/dev/null || true
  # A cgroup can only be removed once its last process has exited.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$CG" ] || break
    rmdir "$CG" 2>/dev/null && break
    sleep 0.2
  done
}
trap cleanup EXIT

# 1. cgroup with limits (swap disabled, otherwise memory.max swaps instead of OOM-killing)
mkdir "$CG"
echo "$MEM_MAX"  > "$CG/memory.max"
echo 0           > "$CG/memory.swap.max"
echo "$PIDS_MAX" > "$CG/pids.max"
echo "$CPU_MAX"  > "$CG/cpu.max"

# 2. Network namespace and a veth "cable"; the container end is renamed to eth0
ip netns add "$NAME"
ip link add "$NAME-h" type veth peer name "$NAME-c"
ip link set "$NAME-c" netns "$NAME"
ip addr add "$HOST_IP" dev "$NAME-h"
ip link set "$NAME-h" up
ip netns exec "$NAME" ip link set "$NAME-c" name eth0
ip netns exec "$NAME" ip addr add "$CONT_IP" dev eth0
ip netns exec "$NAME" ip link set eth0 up
ip netns exec "$NAME" ip link set lo up

# 3. Runs as PID 1 inside the new namespaces, still on the host filesystem at first.
#    $1 = rootfs, $2 = hostname, rest = command to run.
INNER='
set -e
hostname "$2"
mount --bind "$1" "$1"          # pivot_root needs the new root to be a mount point
mkdir -p "$1/.oldroot"
cd "$1"
pivot_root . .oldroot           # rootfs becomes /, host root moves to /.oldroot
cd /
mount -t proc proc /proc        # /proc for the new PID namespace
umount -l /.oldroot             # detach the host filesystem completely
shift 2
[ $# -gt 0 ] || set -- /bin/sh
exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  TERM="${TERM:-xterm}" PS1="[$(hostname)] # " "$@"
'

# 4. Launch: move this subshell into the cgroup first, so everything it starts inherits it;
#    then enter the netns and create the remaining namespaces.
#    --cgroup after the move makes lab0a the cgroup root seen inside.
(
  echo "$BASHPID" > "$CG/cgroup.procs"
  exec ip netns exec "$NAME" \
    unshare --uts --pid --mount --ipc --cgroup --fork --propagation private \
    /bin/sh -c "$INNER" inner "$ROOTFS" "$NAME" "$@"
)
