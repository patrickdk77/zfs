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
#	A scrub and a receive's clonedup pass leave each other alone.
#	A paused scrub does not stop the pass, which clones every copy
#	in its stream.  Scrubs that start and finish while a pass is
#	verifying blocks complete with no error, and so does the pass.
#	A finishing scan asserts that none of its reads are still out,
#	and the pass's verify reads are not the scan's.
#
#	The second part is a stress test: a build that counts the
#	pass's reads as the scan's trips that assertion only when a
#	scrub happens to finish while a verify read is out, and only
#	on a debug build.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_scrub.stream
typeset big=$TEST_BASE_DIR/clonedup_recv_scrub.big
typeset stop=$TEST_BASE_DIR/clonedup_recv_scrub.stop
typeset count=$TEST_BASE_DIR/clonedup_recv_scrub.count
typeset scrub_pid=""
typeset -i nblk=1024

function cleanup
{
	if [[ -n $scrub_pid ]]; then
		touch $stop
		wait $scrub_pid
	fi
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	log_must restore_tunable TXG_TIMEOUT
	rm -f $stream $big $stop $count
	clonedup_cleanup
}

# Scrub the pool again and again until $stop appears.
function scrubber
{
	typeset -i n=0

	while [[ ! -f $stop ]] && kill -0 $$ 2>/dev/null; do
		zpool scrub -w $TESTPOOL 2>/dev/null && ((n += 1))
		echo $n > $count
	done
}

log_assert "a scrub and a receive's clonedup pass leave each" \
    "other alone"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
log_must save_tunable TXG_TIMEOUT

clonedup_pool_create -O recordsize=8k
log_must zfs create -o recordsize=128k $TESTPOOL/s
clonedup_write /$TESTPOOL/s/a $CD_BLOCKS
clonedup_dup /$TESTPOOL/s/a /$TESTPOOL/s/b
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"
log_must zfs create $TESTPOOL/t
log_must dd if=/dev/urandom of=/$TESTPOOL/t/a bs=8k count=$nblk \
    status=none
log_must dd if=/$TESTPOOL/t/a of=/$TESTPOOL/t/b bs=8k status=none
clonedup_sync
log_must zfs snapshot $TESTPOOL/t@1
log_must eval "zfs send $TESTPOOL/t@1 > $big"

# 1. A paused scrub
clonedup_hold
log_must zpool scrub $TESTPOOL
log_must zpool scrub -p $TESTPOOL
clonedup_release
log_must eval "zpool status $TESTPOOL | grep -q 'scrub paused'"
typeset out
out=$(zfs recv -v -k $TESTPOOL/r1 < $stream 2>&1) ||
    log_fail "zfs recv -k failed: $out"
log_note "$out"
[[ $out == *"clonedup: $CD_BLOCKS blocks cloned"* ]] ||
    log_fail "the pass did not clone every copy beside a paused scrub"
clonedup_sync
clonedup_check_shared $TESTPOOL/r1 a $TESTPOOL/r1 b \
    "$(clonedup_all_blocks)"
log_must zpool scrub $TESTPOOL
log_must zpool wait -t scrub $TESTPOOL

# 2. Scrubs that finish while a pass verifies, paced so that the
# pass spans many txgs
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG 32
log_must set_tunable32 TXG_TIMEOUT 1
rm -f $stop $count
scrubber &
scrub_pid=$!
out=$(zfs recv -v -k $TESTPOOL/r2 < $big 2>&1) ||
    log_fail "zfs recv -k failed: $out"
log_note "$out"
log_must touch $stop
wait $scrub_pid
scrub_pid=""
typeset -i nscrub=$(<$count)
log_note "$nscrub scrubs finished during the receive"
(( nscrub >= 2 )) || log_fail "too few scrubs overlapped the pass"
[[ $out == *"clonedup: $nblk blocks cloned"* ]] ||
    log_fail "the pass did not clone every copy beside the scrubs"
log_must eval "zpool status $TESTPOOL |" \
    "grep -q 'scrub repaired 0B .* with 0 errors on'"
log_must eval "zpool status -v $TESTPOOL |" \
    "grep -q 'errors: No known data errors'"
log_must cmp /$TESTPOOL/t/a /$TESTPOOL/r2/a
log_must cmp /$TESTPOOL/t/b /$TESTPOOL/r2/b
clonedup_leakcheck

log_pass "a scrub and a receive's clonedup pass leave each other" \
    "alone"
