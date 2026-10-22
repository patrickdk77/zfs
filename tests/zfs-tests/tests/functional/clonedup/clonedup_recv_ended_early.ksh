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
#	A receive's clonedup pass that is switched off partway
#	through its apply ends early.  The receive still succeeds,
#	and zfs receive reports on stderr, without -v, that the pass
#	ended early and how many blocks it cloned before it did.  It
#	does not report the pass as skipped.
#
# STRATEGY:
#	1. Send a stream that holds two copies of 64 blocks.
#	2. Receive it with -k on one worker that sleeps a second per
#	   candidate.
#	3. Once the pass is applying, set zfs_clonedup_apply_enabled
#	   to 0.
#	4. Check the warning, the count it gives and the data.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_ended_early.stream
typeset errf=$TEST_BASE_DIR/clonedup_recv_ended_early.err
typeset recv_pid=""
typeset -i nblk=64

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_ENABLED
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	[[ -n $recv_pid ]] && wait $recv_pid
	rm -f $stream $errf
	clonedup_cleanup
}

log_assert "a receive's pass cut short reports what it cloned"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_ENABLED
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS

clonedup_pool_create
log_must zfs create $TESTPOOL/s
clonedup_write /$TESTPOOL/s/a $nblk
clonedup_dup /$TESTPOOL/s/a /$TESTPOOL/s/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"

log_must set_tunable32 CLONEDUP_APPLY_THREADS 1
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 1000
typeset -i runs=$(clonedup_kstat recv_runs) i
zfs recv -k $TESTPOOL/r < $stream 2> $errf &
recv_pid=$!
for ((i = 0; i < 300; i++)); do
	(( $(clonedup_kstat recv_runs) > runs )) && break
	sleep 0.1
done
(( $(clonedup_kstat recv_runs) > runs )) ||
    log_fail "the receive never started its pass"

# a few candidates into the apply, at a second each
sleep 3
log_must set_tunable32 CLONEDUP_APPLY_ENABLED 0
wait $recv_pid
typeset -i rc=$?
recv_pid=""
typeset err="$(<$errf)"
log_note "zfs recv -k exited $rc: $err"
(( rc == 0 )) || log_fail "zfs recv -k exited $rc"

typeset msg="Warning: clonedup pass on $TESTPOOL/r ended early after"
typeset cloned=$(echo "$err" | awk -v m="$msg" '
    index($0, m) == 1 { split(substr($0, length(m) + 2), w, " ");
    print w[1] }')
[[ $cloned == +([0-9]) ]] ||
    log_fail "the pass that ended early was not reported"
log_note "the pass cloned $cloned of $nblk blocks before it ended"
(( cloned < nblk )) || log_fail "the pass was not cut short"
[[ $err == *"pass skipped"* ]] &&
    log_fail "the pass was reported as skipped"
clonedup_kstat_is recv_runs $((runs + 1))

log_must datasetexists $TESTPOOL/r@1
log_must cmp /$TESTPOOL/r/a /$TESTPOOL/s/a
log_must cmp /$TESTPOOL/r/b /$TESTPOOL/s/b
clonedup_leakcheck

log_pass "a receive's pass cut short reports what it cloned"
