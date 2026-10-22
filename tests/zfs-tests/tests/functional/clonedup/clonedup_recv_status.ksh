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
#	While zfs receive -k runs its clonedup pass, zpool status
#	still reports the last clonedup run.  The pass keeps its own
#	counts in the run's in-memory record and puts the saved record
#	back when it ends, so status has to report the saved copy
#	until then.
#
# STRATEGY:
#	1. Run clonedup on a pair of duplicate files and record the
#	   counts zpool status reports.
#	2. Slow the apply down and start zfs receive -k of a stream
#	   that holds its own duplicates.
#	3. Poll zpool status until the receive exits, and check every
#	   poll against the recorded counts.
#	4. Require at least one poll inside the pass, one after which
#	   the clones kstat shows the pass still had blocks to clone.
#	5. Check the counts again after the receive, and check that
#	   the pass cloned the stream's duplicates.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_status.stream
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

# Every field of the pool's scan stats a clonedup run sets.
function cd_counts
{
	zpool status -j --json-int $TESTPOOL |
	    jq -c --arg p $TESTPOOL '.pools[$p].scan_stats |
	    with_entries(select(.key | startswith("clonedup_") or
	    . == "examined" or . == "to_examine" or . == "state" or
	    . == "errors"))'
}

log_assert "zpool status reports the last run during a receive's pass"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
log_must zfs create $TESTPOOL/s
clonedup_write /$TESTPOOL/s/c $nblk
clonedup_dup /$TESTPOOL/s/c /$TESTPOOL/s/d
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"

clonedup_run
typeset want=$(cd_counts)
log_note "after the run: $want"
log_must [ "$(clonedup_jstat clonedup_applied)" -gt 0 ]

# One worker and a quarter second per candidate keep the pass in
# its apply for about eight seconds.
log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 250
typeset -i runs=$(clonedup_kstat recv_runs)
typeset -i clones=$(clonedup_kstat clones)
typeset -i i inside=0
typeset got
zfs recv -k $TESTPOOL/r < $stream &
recv_pid=$!
for ((i = 0; i < 300; i++)); do
	(( $(clonedup_kstat recv_runs) > runs )) && break
	sleep 0.1
done
(( $(clonedup_kstat recv_runs) > runs )) ||
    log_fail "the receive never started its pass"

#
# The pass clones nblk blocks and ends after the last of them, so a
# poll landed inside the pass when the clones kstat had not gone up
# by nblk by the time the poll returned.
#
for ((i = 0; i < 1200; i++)); do
	kill -0 $recv_pid 2>/dev/null || break
	got=$(cd_counts)
	[[ "$got" == "$want" ]] ||
	    log_fail "during the receive: '$got', want '$want'"
	if (( $(clonedup_kstat clones) - clones < nblk )); then
		(( inside += 1 ))
	fi
	sleep 0.1
done
log_note "$inside polls landed inside the pass"
log_must [ $inside -ge 1 ]

pid_wait_exit $recv_pid 120 ||
    log_fail "zfs recv did not exit within 120 s of the polls"
wait $recv_pid
typeset -i rc=$?
recv_pid=""
log_must [ $rc -eq 0 ]
got=$(cd_counts)
[[ "$got" == "$want" ]] ||
    log_fail "after the receive: '$got', want '$want'"

log_must datasetexists $TESTPOOL/r@1
clonedup_kstat_is clones $((clones + nblk))
clonedup_sync
clonedup_check_shared $TESTPOOL/r c $TESTPOOL/r d \
    "$(clonedup_all_blocks $nblk)"
clonedup_leakcheck

log_pass "zpool status reports the last run during a receive's pass"
