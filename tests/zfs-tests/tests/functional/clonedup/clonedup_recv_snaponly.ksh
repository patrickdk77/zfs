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
#	zfs receive -K matches the received blocks against the blocks
#	that snapshots hold, and not against a block that only a live
#	dataset holds.  A live dataset can change on disk under a
#	walk made in open context, so the match walk leaves it out.
#
# STRATEGY:
#	1. Send a dataset to a file and destroy the dataset, so the
#	   only copies of its blocks left on the pool are the ones
#	   the test writes.
#	2. Write a copy into a dataset that has no snapshot and
#	   receive with -K.  The received blocks share nothing with
#	   that copy.
#	3. Destroy both.  Write a copy into another dataset, snapshot
#	   it and remove the file from the head.  Receive with -K.
#	   The received blocks share the snapshot's.
#

verify_runnable "global"

typeset data=$TEST_BASE_DIR/clonedup_recv_snaponly.data
typeset stream=$TEST_BASE_DIR/clonedup_recv_snaponly.stream
typeset cloned=""

function cleanup
{
	rm -f $data $stream
	clonedup_cleanup
}

#
# Log a file's L0 blocks and fail unless zdb listed CD_BLOCKS of
# them, so a comparison that had nothing to compare cannot pass.
#
function snaponly_listed # ds file
{
	typeset b=$(clonedup_file_blocks $1 $2 | awk '{ print $2 }')
	typeset -i n=$(echo $b | wc -w)

	log_note "$1 $2: $n blocks: $(echo $b)"
	(( n == CD_BLOCKS )) ||
	    log_fail "zdb listed $n blocks of $1 $2, want $CD_BLOCKS"
}

#
# Receive the stream into ds with -K.  The pass must report its
# result and have made one match walk.  The blocks it cloned are
# left in $cloned.
#
function snaponly_recv # ds
{
	typeset -i walks=$(clonedup_kstat match_walks)
	typeset out

	out=$(zfs recv -v -K $1 < $stream 2>&1) ||
	    log_fail "receive into $1 failed: $out"
	log_note "$out"
	cloned=$(echo "$out" |
	    awk '$1 == "clonedup:" && $3 == "blocks" { print $2 }')
	[[ -n $cloned ]] || log_fail "the receive into $1 ran no pass"
	clonedup_kstat_is match_walks $((walks + 1))
	clonedup_sync
}

log_assert "zfs receive -K matches blocks a snapshot holds, not" \
    "blocks only a live dataset holds"
log_onexit cleanup
typeset all="$(clonedup_all_blocks)"

clonedup_pool_create
clonedup_write $data
log_must zfs create $TESTPOOL/src
clonedup_dup $data /$TESTPOOL/src/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"
log_must zfs destroy -r $TESTPOOL/src
log_must zpool wait -t free $TESTPOOL

# 1. The only other copy is in a dataset with no snapshot.
log_must zfs create $TESTPOOL/live
clonedup_dup $data /$TESTPOOL/live/f
clonedup_sync
snaponly_recv $TESTPOOL/r1
log_must cmp $data /$TESTPOOL/live/f
log_must cmp $data /$TESTPOOL/r1/f
snaponly_listed $TESTPOOL/live f
snaponly_listed $TESTPOOL/r1 f
clonedup_check_shared $TESTPOOL/live f $TESTPOOL/r1 f ""
log_note "the receive into r1 cloned '$cloned' blocks (want 0)"
log_must [ "$cloned" -eq 0 ]

log_must zfs destroy -r $TESTPOOL/r1
log_must zfs destroy -r $TESTPOOL/live
log_must zpool wait -t free $TESTPOOL

# 2. The only other copy is held by a snapshot alone.
log_must zfs create $TESTPOOL/held
clonedup_dup $data /$TESTPOOL/held/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/held@s
log_must rm /$TESTPOOL/held/f
clonedup_sync
snaponly_recv $TESTPOOL/r2
log_must cmp $data /$TESTPOOL/r2/f
snaponly_listed $TESTPOOL/held@s f
snaponly_listed $TESTPOOL/r2 f
clonedup_check_shared $TESTPOOL/held@s f $TESTPOOL/r2 f "$all"
log_note "the receive into r2 cloned '$cloned' blocks" \
    "(want $CD_BLOCKS)"
log_must [ "$cloned" -eq $CD_BLOCKS ]

clonedup_leakcheck

log_pass "zfs receive -K matches blocks a snapshot holds, not" \
    "blocks only a live dataset holds"
