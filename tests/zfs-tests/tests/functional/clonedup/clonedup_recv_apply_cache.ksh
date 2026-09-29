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
#	A zfs receive -k that arrives while a clonedup run is
#	applying skips its pass with EBUSY, and never reads a dataset
#	through the dataset cache of the apply thread's first worker,
#	which that worker uses without a lock.
#	zfs_clonedup_dscache_log names each dataset read into an
#	apply cache, so a received dataset showing up there is a
#	receive that touched the cache.  The receives run against an
#	apply spread over many datasets, and the run and the pool are
#	intact afterwards.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_apply_cache.stream
typeset -i ndst=8 nrecv=20

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	log_must restore_tunable CLONEDUP_YIELD_TIMEOUT_MS
	log_must restore_tunable CLONEDUP_DSCACHE_LOG
	rm -f $stream
	clonedup_cleanup
}

log_assert "a refused receive leaves the apply's cache alone"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS
log_must save_tunable CLONEDUP_YIELD_TIMEOUT_MS
log_must save_tunable CLONEDUP_DSCACHE_LOG

clonedup_pool_create

# the stream each receive replays: two copies, so -k has work
log_must zfs create $TESTPOOL/s
clonedup_write /$TESTPOOL/s/a
clonedup_dup /$TESTPOOL/s/a /$TESTPOOL/s/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"

# a copy in each of ndst datasets keeps the apply's cache filling
log_must zfs create $TESTPOOL/src
clonedup_write /$TESTPOOL/src/f
typeset -i i
for ((i = 0; i < ndst; i++)); do
	log_must zfs create $TESTPOOL/d$i
	clonedup_dup /$TESTPOOL/src/f /$TESTPOOL/d$i/f
done
clonedup_sync

# One worker and a second per candidate give about a minute of apply.
# A yield that gives up after a millisecond lets each receive reach
# its pass while that worker is still busy.
log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 1000
log_must set_tunable32 CLONEDUP_YIELD_TIMEOUT_MS 1
log_must set_tunable32 CLONEDUP_DSCACHE_LOG 1

log_must zpool clonedup $TESTPOOL
clonedup_wait_applying
sleep 1

typeset id msgs
for ((i = 0; i < nrecv; i++)); do
	zpool status $TESTPOOL | grep -q applying ||
	    log_fail "the apply ended after $i receives"
	log_must eval "zfs recv -k $TESTPOOL/r$i < $stream"
	id=$(zfs get -Hpo value objsetid $TESTPOOL/r$i)
	msgs=$(kstat dbgmsg)
	echo "$msgs" | grep -q \
	    "receive into $TESTPOOL/r$i: pass skipped, err 16" ||
	    log_fail "the pass into r$i was not skipped with EBUSY"
	if echo "$msgs" | grep -q "dataset $id missed the apply"; then
		log_fail "the receive into r$i read dataset $id" \
		    "through the apply's cache"
	fi
done
clonedup_kstat_is recv_runs 0

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 0
log_must timeout 600 zpool wait -t clonedup $TESTPOOL
clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_stat_is $CDS_ERRORS 0
clonedup_stat_gt $CDS_APPLIED 0
clonedup_leakcheck

log_pass "a refused receive leaves the apply's cache alone"
