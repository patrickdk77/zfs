#!/usr/bin/env bash
#
# qemu-6-xfstests.sh -- the "Run tests" step, xfstests variant.
#
# Drop-in analog of .github/workflows/scripts/qemu-6-tests.sh: instead of ZTS
# it runs the reflink(clone)/dedupe/fiemap fstests groups across a ZFS pool
# topology matrix and diffs the result against per-topology baselines. Reuses
# the same qemu-1..5 setup, and needs no extra disks -- the pool vdevs are
# loop-backed files on the existing tests disk (xfs @ /var/tmp on /dev/vdb),
# exactly like qemu-6-tests.sh.
#
# Runs inside the qemu test VM.
#
set -eu

OS="${1:-unknown}"
# Location of the runner bits (this file's dir).
DIR=$(cd "$(dirname "$0")" && pwd)
echo "== xfstests topology run on $OS =="

# Same tests-disk prep as qemu-6-tests.sh, but mount at /mnt/repro so all
# scratch/results/loop-backing live on the roomy disk, never the OS /var/tmp.
sudo -E modprobe zfs
sudo mkfs.xfs -fq /dev/vdb
sudo mkdir -p /mnt/repro
sudo mount -o noatime /dev/vdb /mnt/repro
sudo chmod 1777 /mnt/repro

# Longer RCU/watchdog timeouts (heavily virtualized), as in qemu-6-tests.sh.
t=/sys/module/rcupdate/parameters/rcu_cpu_stall_timeout
if [ -f "$t" ]; then echo 120 | sudo tee "$t" >/dev/null; fi

# Build + patch fstests.
sudo XFSTESTS_DIR=/mnt/repro/xfstests "$DIR/setup.sh"

TOPOS="${TOPOLOGIES:-single-a12 single-a9 stripe3 raidz1}"
XFS_GROUPS="${XFS_GROUPS:-clone dedupe fiemap}"

# Run the matrix. DISKS unset -> run-xfstests.sh makes 5 loop-backed vdevs
# under $SCRATCHROOT (on the tests disk). ashift is forced per topology.
RV=0
sudo XFSTESTS_DIR=/mnt/repro/xfstests SCRATCHROOT=/mnt/repro TMPDIR=/mnt/repro \
	TOPOLOGIES="$TOPOS" XFS_GROUPS="$XFS_GROUPS" \
	"$DIR/run-xfstests.sh" || RV=$?

# Summarize vs baselines (self-skips shown; new failures -> non-zero).
args=()
for t in $TOPOS; do args+=( "$t=/mnt/repro/xfstests-results/$t.log" ); done
"$DIR/xfstests-report.sh" "$DIR/baseline" "$DIR/unsafe-excludes.txt" "${args[@]}" \
	| tee /mnt/repro/xfstests-summary.txt || RV=$?

# Match qemu-6-tests.sh's result contract for the summary step.
cp -f /mnt/repro/xfstests-summary.txt /tmp/summary.txt 2>/dev/null || true
echo "$RV" > /var/tmp/tests-exitcode.txt
sync
exit 0
