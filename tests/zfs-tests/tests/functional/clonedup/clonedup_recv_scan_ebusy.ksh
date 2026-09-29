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
#	While a zfs receive -k pass owns the clonedup index, zpool
#	clonedup fails with EBUSY instead of setting up a run over it.
#	The pass then finishes with every duplicate in the stream
#	cloned, and a run started afterwards completes.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_scan_ebusy.stream
typeset recv_pid=""
typeset -i nblk=32

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

log_assert "zpool clonedup fails with EBUSY while a receive pass runs"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS
typeset all="$(clonedup_all_blocks $nblk)"

clonedup_pool_create
log_must zfs create $TESTPOOL/src
clonedup_write /$TESTPOOL/src/a $nblk
clonedup_dup /$TESTPOOL/src/a /$TESTPOOL/src/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"
clonedup_kstat_is recv_runs 0

# One worker sleeping half a second per candidate holds the pass's
# apply open for about nblk / 2 seconds.
log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 500

zfs recv -k $TESTPOOL/rcv < $stream &
recv_pid=$!

typeset -i i
for ((i = 0; i < 600; i++)); do
	(( $(clonedup_kstat recv_runs) > 0 )) && break
	kill -0 $recv_pid 2>/dev/null || break
	sleep 0.1
done
(( $(clonedup_kstat recv_runs) > 0 )) ||
    log_fail "the receive pass did not start"
kill -0 $recv_pid 2>/dev/null ||
    log_fail "the receive ended before zpool clonedup ran"

typeset out
typeset -i rc
out=$(zpool clonedup $TESTPOOL 2>&1)
rc=$?
log_note "zpool clonedup during the pass: rc $rc: $out"
(( rc != 0 )) ||
    log_fail "zpool clonedup started a run while the receive pass ran"
[[ $out == *receive* ]] ||
    log_fail "zpool clonedup failed for another reason: $out"

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 0
pid_wait_exit $recv_pid 300 || log_fail "the receive did not finish"
wait $recv_pid
rc=$?
recv_pid=""
(( rc == 0 )) || log_fail "zfs recv -k exited $rc"

# -k clones the stream's copies onto each other and leaves src alone
clonedup_sync
clonedup_kstat_is recv_runs 1
clonedup_check_shared $TESTPOOL/rcv a $TESTPOOL/rcv b "$all"
clonedup_check_shared $TESTPOOL/src a $TESTPOOL/rcv a ""

# a run started once the pass is over completes and clones
log_must zfs create $TESTPOOL/post
clonedup_write /$TESTPOOL/post/x
clonedup_dup /$TESTPOOL/post/x /$TESTPOOL/post/y
clonedup_sync
clonedup_run
clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_stat_is $CDS_ERRORS 0
clonedup_check_shared $TESTPOOL/post x $TESTPOOL/post y \
    "$(clonedup_all_blocks)"

clonedup_leakcheck

log_pass "zpool clonedup fails with EBUSY while a receive pass runs"
