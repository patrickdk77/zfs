#!/usr/bin/env bash
#
# run-xfstests.sh -- run the ZFS xfstests groups across a topology matrix.
#
# For each topology it builds the scratch pool over the given disks (topology
# and ashift chosen per-run, so the same disks serve every layout), points the
# per-test scratch mkfs at that vdev spec via ZFS_SCRATCH_VDEV (see
# topology.patch for common/zfs), runs the target groups with the unsafe tests
# excluded (-E), and saves one check log per topology under $RESDIR. Feed those
# logs to xfstests-report.sh.
#
# Disks: provide DISKS as a space-separated list of at least 5 block devices
# (real disks preferred, e.g. "/dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf").
# DISKS[0] is the persistent TEST pool; DISKS[1..] are the scratch pool (up to
# 4 used, for raidz1). ashift is forced via `zpool create -o ashift`, so one
# set of disks covers both the a12 and a9 single-device layouts.
# If DISKS is unset, falls back to loop files under $DEVDIR (local dev only).
#
# Assumes: ZFS module built+loaded, xfstests built+installed. Run via sudo.
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
XFSTESTS_DIR=${XFSTESTS_DIR:-/var/tmp/xfstests}
XFS_GROUPS=${XFS_GROUPS:-"clone dedupe fiemap"}
TOPOLOGIES=${TOPOLOGIES:-"single-a12 single-a9 stripe3 raidz1"}
DISKS=${DISKS:-}
# Keep scratch/results on a roomy disk, not the OS /var/tmp.
SCRATCHROOT=${SCRATCHROOT:-/mnt/repro}
DEVDIR=${DEVDIR:-$SCRATCHROOT/xfstests-devs}
DEVSIZE=${DEVSIZE:-50G}
RESDIR=${RESDIR:-$SCRATCHROOT/xfstests-results}
UNSAFE="$HERE/unsafe-excludes.txt"
SCRATCH_MNT=${SCRATCH_MNT:-/mnt/scratch}
TEST_MNT=${TEST_MNT:-/mnt/test}

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
mkdir -p "$RESDIR" "$DEVDIR" "$SCRATCH_MNT" "$TEST_MNT"

# Resolve the disk pool: real DISKS if given, else 5 loop files (local dev).
if [ -n "$DISKS" ]; then
	read -r -a DISKV <<<"$DISKS"
else
	echo "DISKS unset -> using 5 loop files under $DEVDIR ($DEVSIZE each)"
	DISKV=()
	for i in 0 1 2 3 4; do
		f="$DEVDIR/disk$i.img"; rm -f "$f"; truncate -s "$DEVSIZE" "$f"
		DISKV+=( "$(losetup --find --show "$f")" )
	done
fi
[ "${#DISKV[@]}" -ge 5 ] || { echo "need >=5 disks (1 test + 4 scratch); have ${#DISKV[@]}"; exit 1; }
TEST_DISK="${DISKV[0]}"
SCRATCH_DISKS=( "${DISKV[@]:1}" )
echo "TEST disk:    $TEST_DISK"
echo "SCRATCH disks: ${SCRATCH_DISKS[*]}"

# topology -> "<ashift> <nr-scratch-devs> <vdev-keyword>"
topo_spec() {
	case "$1" in
		single-a12) echo "12 1 " ;;
		single-a9)  echo "9 1 " ;;
		stripe3)    echo "12 3 " ;;
		raidz1)     echo "12 4 raidz" ;;
		mirror3)    echo "12 3 mirror" ;;
		*) echo "unknown topology: $1" >&2; return 1 ;;
	esac
}

# unsafe test list for -E (one per line, comments stripped)
unsafe_file() {
	grep -vE '^\s*#|^\s*$' "$UNSAFE" 2>/dev/null | awk '{print $1}' > "$RESDIR/exclude.list"
	echo "$RESDIR/exclude.list"
}

EXCL=$(unsafe_file)
echo "topologies: $TOPOLOGIES"
echo "groups:     $XFS_GROUPS"
echo "excluding (unsafe): $(tr '\n' ' ' < "$EXCL")"

for topo in $TOPOLOGIES; do
	read -r ashift ndev vdev <<<"$(topo_spec "$topo")" || { echo "skip $topo"; continue; }
	echo "========================================================"
	echo "topology $topo: ashift=$ashift devs=$ndev vdev='${vdev:-stripe/single}'"

	# scratch vdev spec from the first $ndev scratch disks + optional keyword
	SDEVS=( "${SCRATCH_DISKS[@]:0:$ndev}" )
	[ "${#SDEVS[@]}" -eq "$ndev" ] || { echo "need $ndev scratch disks for $topo, have ${#SDEVS[@]}; skipping"; continue; }
	SCRATCH_VDEV="${vdev:+$vdev }${SDEVS[*]}"

	# persistent test pool + dataset on TEST_DISK
	zpool destroy -f testpool 2>/dev/null || true
	zpool labelclear -f "$TEST_DISK" 2>/dev/null || true
	zpool create -f -o "ashift=$ashift" -O mountpoint=legacy testpool "$TEST_DISK"
	zfs create -o mountpoint=legacy testpool/test

	# xfstests config; scratch pool is (re)built per test by _scratch_mkfs,
	# whose vdev spec comes from ZFS_SCRATCH_VDEV (topology.patch).
	cat > "$XFSTESTS_DIR/local.config" <<CFG
export FSTYP=zfs
export TEST_DEV=testpool/test
export TEST_DIR=$TEST_MNT
export SCRATCH_DEV=${SDEVS[0]}
export SCRATCH_MNT=$SCRATCH_MNT
export SCRATCH_ZPOOL_NAME=scratch
export ZFS_SCRATCH_VDEV="$SCRATCH_VDEV"
export MKFS_OPTIONS="-o ashift=$ashift"
CFG

	log="$RESDIR/$topo.log"
	read -ra grps <<<"$XFS_GROUPS"
	grp_args=(); for g in "${grps[@]}"; do grp_args+=( -g "$g" ); done
	( cd "$XFSTESTS_DIR" && ./check -E "$EXCL" "${grp_args[@]}" ) 2>&1 | tee "$log"

	# cleanup pools for the next topology (real disks: nothing to detach)
	zpool destroy -f scratch 2>/dev/null || true
	zpool destroy -f testpool 2>/dev/null || true
done

echo "========================================================"
echo "logs in $RESDIR ; summarize with:"
echo "  $HERE/xfstests-report.sh $HERE/baseline $UNSAFE $(for t in $TOPOLOGIES; do printf '%s=%s/%s.log ' "$t" "$RESDIR" "$t"; done)"
