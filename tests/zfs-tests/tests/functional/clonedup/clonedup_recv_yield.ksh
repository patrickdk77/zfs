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
#	A destroy that asks the apply to yield while a receive's pass
#	is applying gets its answer at once, as it would from a run's
#	apply: the pass lets go of what it holds, the destroy goes
#	through, and the pass carries on.  That holds for a snapshot
#	the pass has nothing to do with, and for the snapshot it takes
#	its sources from.
#
# STRATEGY:
#	1. Send a stream of two copies of 64 blocks, then destroy its
#	   dataset, so that the copies the test writes are the only
#	   others on the pool.
#	2. Set the yield timeout to two minutes, and slow the apply to
#	   a second a candidate on one worker.
#	3. Receive with -k and destroy an unrelated snapshot during
#	   the apply.
#	4. Receive with -K, where the only other copy is held by a
#	   snapshot alone, and destroy that snapshot during the apply.
#	5. Each destroy must return within ten seconds while its pass
#	   is still running, and each receive must keep its data.
#

verify_runnable "global"

typeset data=$TEST_BASE_DIR/clonedup_recv_yield.data
typeset stream=$TEST_BASE_DIR/clonedup_recv_yield.stream
typeset recv_pid=""
typeset -i nblk=64 bound=10

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	log_must restore_tunable CLONEDUP_YIELD_TIMEOUT_MS
	[[ -n $recv_pid ]] && wait $recv_pid
	rm -f $data $stream
	clonedup_cleanup
}

#
# Start zfs recv with args in the background, and return once its
# pass has spent a few seconds in its apply.
#
function yield_start # args...
{
	typeset -i runs=$(clonedup_kstat recv_runs) i

	log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 1000
	zfs recv "$@" < $stream &
	recv_pid=$!
	for ((i = 0; i < 300; i++)); do
		(( $(clonedup_kstat recv_runs) > runs )) && break
		sleep 0.1
	done
	(( $(clonedup_kstat recv_runs) > runs )) ||
	    log_fail "zfs recv $* never started its pass"
	sleep 3
	kill -0 $recv_pid 2>/dev/null ||
	    log_fail "zfs recv $* ended before the destroy"
}

# Destroy snap, which must be quick and leave the pass running.
function yield_destroy # snap
{
	typeset -F start=$SECONDS t

	log_must zfs destroy $1
	((t = SECONDS - start))
	log_note "zfs destroy $1 took $t seconds"
	(( t < bound )) ||
	    log_fail "zfs destroy $1 waited $t seconds for the pass"
	kill -0 $recv_pid 2>/dev/null ||
	    log_fail "the pass ended before zfs destroy $1 returned"
}

# Let the pass finish, and check the receive and its data.
function yield_finish # ds
{
	typeset -i rc

	log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 0
	wait $recv_pid
	rc=$?
	recv_pid=""
	(( rc == 0 )) || log_fail "the receive into $1 exited $rc"
	log_must datasetexists $1@1
	log_must cmp $data /$1/a
	log_must cmp $data /$1/b
}

log_assert "a receive's pass lets go when a destroy asks"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS
log_must save_tunable CLONEDUP_YIELD_TIMEOUT_MS

clonedup_pool_create
clonedup_write $data $nblk
log_must zfs create $TESTPOOL/s
clonedup_dup $data /$TESTPOOL/s/a
clonedup_dup $data /$TESTPOOL/s/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"
log_must zfs destroy -r $TESTPOOL/s

log_must zfs create $TESTPOOL/o
clonedup_write /$TESTPOOL/o/x
clonedup_sync
log_must zfs snapshot $TESTPOOL/o@x
log_must zfs create $TESTPOOL/h
clonedup_dup $data /$TESTPOOL/h/a
clonedup_sync
log_must zfs snapshot $TESTPOOL/h@s
log_must rm /$TESTPOOL/h/a
clonedup_sync
log_must zpool wait -t free $TESTPOOL

log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_YIELD_TIMEOUT_MS 120000

# 1. -k, and a snapshot the pass has nothing to do with
yield_start -k $TESTPOOL/r1
yield_destroy $TESTPOOL/o@x
yield_finish $TESTPOOL/r1
log_must zfs destroy -r $TESTPOOL/r1
log_must zpool wait -t free $TESTPOOL

# 2. -K, and the snapshot that holds the sources
yield_start -K $TESTPOOL/r2
yield_destroy $TESTPOOL/h@s
yield_finish $TESTPOOL/r2
clonedup_leakcheck

log_pass "a receive's pass lets go when a destroy asks"
