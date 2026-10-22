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
#	A signal to zfs receive -k during its clonedup pass ends the
#	pass at the next group with EINTR, before it has cloned
#	every copy.  The pass runs in the
#	receiving thread and can walk every snapshot on the pool, so
#	it has to answer a signal the way a send or a receive stream
#	does.  The stream is already received by then, so the
#	snapshot is still created and intact.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_interrupt.stream
typeset recv_pid=""
typeset -i nblk=64

# Wait up to secs seconds for a process to exit.
function pid_wait_exit # pid secs
{
	typeset -i i

	for ((i = 0; i < $2 * 10; i++)); do
		kill -0 $1 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	if [[ -n $recv_pid ]]; then
		if pid_wait_exit $recv_pid 300; then
			wait $recv_pid
		else
			log_note "receive $recv_pid is still running"
		fi
	fi
	rm -f $stream
	clonedup_cleanup
}

log_assert "a signal ends a receive's clonedup pass"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS

clonedup_pool_create
log_must zfs create $TESTPOOL/s
clonedup_write /$TESTPOOL/s/a $nblk
clonedup_dup /$TESTPOOL/s/a /$TESTPOOL/s/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"

# One worker and a second per candidate keep the pass in its
# apply for about a minute if nothing stops it.
log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 1000
typeset -i runs=$(clonedup_kstat recv_runs) i
typeset -i clones=$(clonedup_kstat clones)
zfs recv -k $TESTPOOL/r < $stream &
recv_pid=$!
for ((i = 0; i < 300; i++)); do
	(( $(clonedup_kstat recv_runs) > runs )) && break
	sleep 0.1
done
(( $(clonedup_kstat recv_runs) > runs )) ||
    log_fail "the receive never started its pass"
sleep 1

typeset -F start=$SECONDS
# A shell starts background jobs with SIGINT ignored, so the
# signal is SIGTERM.
log_must kill -TERM $recv_pid
pid_wait_exit $recv_pid 60 ||
    log_fail "zfs recv did not exit within 60 s of the signal"
wait $recv_pid
typeset -i rc=$?
recv_pid=""
log_note "zfs recv ended $((SECONDS - start)) s after the signal"
log_note "zfs recv exited $rc"
# After the pass the receive still waits for its txg to sync,
# which can take seconds, so the bound is half the pass.
(( SECONDS - start < 30 )) ||
    log_fail "the pass ran on after the signal"
((clones = $(clonedup_kstat clones) - clones))
log_note "the pass cloned $clones of $nblk copies"
log_must [ $clones -lt $nblk ]

log_must datasetexists $TESTPOOL/r@1
log_must zfs mount -a
log_must cmp /$TESTPOOL/r/a /$TESTPOOL/s/a
log_must cmp /$TESTPOOL/r/b /$TESTPOOL/s/b
clonedup_leakcheck

log_pass "a signal ends a receive's clonedup pass"
