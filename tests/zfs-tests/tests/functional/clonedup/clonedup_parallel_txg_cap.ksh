#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#
#
# Copyright (c) 2026, Patrick Domack. All rights reserved.
#

. $STF_SUITE/tests/functional/clonedup/clonedup.kshlib

#
# DESCRIPTION:
#	zfs_clonedup_apply_blocks_per_txg caps the clones in one txg
#	across all apply workers.  Each destination file holds one
#	block to clone and one unique block, so it has an L1, and the
#	clone rewrites that L1 in the txg the clone lands in.  The L1
#	birth txgs count the clones in each txg.  Two workers run
#	with a cap of four and every batch holds its transaction open
#	for a second, so the two workers' batches meet in one txg
#	unless the cap turns the second one away.
#

verify_runnable "global"

typeset -ri nfiles=32
typeset -ri cap=4
typeset -ri hold_ms=1000
typeset -r fs=$TESTPOOL/fs
typeset -r dir=/$TESTPOOL/fs

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_COMMIT_DELAY
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	clonedup_cleanup
}

# "path txg" for the L1 of every destination file
function l1_births
{
	zdb -ddddd $fs | awk '
	    /^ *Object +lvl/ { path = "" }
	    /^\tpath\t/ { path = $2 }
	    / L1 / && path ~ /^\/d[0-9]+$/ {
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^B=/) {
				split(substr($i, 3), b, "/")
				print path, b[1]
			}
		}
		path = ""
	    }'
}

log_assert "the per-txg clone cap holds across apply workers"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_COMMIT_DELAY
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
log_must save_tunable CLONEDUP_APPLY_THREADS

clonedup_pool_create
log_must zfs create $fs

# The source goes in first, so its blocks are the older copies and
# the apply clones them onto the destinations.
clonedup_write $dir/a $nfiles
clonedup_sync
for ((i = 0; i < nfiles; i++)); do
	log_must dd if=$dir/a of=$dir/d$i bs=$CD_BS skip=$i count=1 \
	    status=none
	log_must dd if=/dev/urandom of=$dir/d$i bs=$CD_BS seek=1 \
	    count=1 conv=notrunc status=none
done
clonedup_sync

typeset before=$(l1_births)
typeset -i nbefore=$(echo "$before" | grep -c .)
typeset -i written=$(echo "$before" |
    awk '$2 > m { m = $2 } END { print m + 0 }')
log_note "$nbefore destination L1s, newest from txg $written"
log_must [ $nbefore -eq $nfiles ]

log_must set_tunable32 CLONEDUP_APPLY_THREADS 2
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG $cap
log_must set_tunable32 CLONEDUP_APPLY_COMMIT_DELAY $hold_ms

typeset -i kbefore=$(clonedup_kstat clones)
clonedup_run
typeset -i clones=$(( $(clonedup_kstat clones) - kbefore ))
log_note "kstat clones $clones"
log_must [ $clones -eq $nfiles ]

clonedup_sync
typeset after=$(l1_births)
typeset -i nafter=$(echo "$after" | awk -v w=$written '$2 > w' |
    grep -c .)
log_note "$nafter of $nfiles destination L1s rewritten by the run"
log_must [ $nafter -eq $nfiles ]

typeset hist=$(echo "$after" |
    awk '{ n[$2]++ } END { for (t in n) print t, n[t] }' | sort -n)
typeset -i most=$(echo "$hist" |
    awk '$2 > m { m = $2 } END { print m + 0 }')
log_note "clones per txg: $(echo "$hist" | tr '\n' ',')"
log_note "most clones in one txg: $most, cap $cap"
log_must [ $most -le $cap ]

clonedup_leakcheck

log_pass "the per-txg clone cap holds across apply workers"
