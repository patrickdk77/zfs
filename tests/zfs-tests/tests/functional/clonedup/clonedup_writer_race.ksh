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
#	A file being rewritten while its duplicates are cloned never
#	loses a write.  Every write also goes to a shadow copy; the
#	two must match afterwards.
#

verify_runnable "global"

typeset writer_pid=""

function cleanup
{
	[[ -n $writer_pid ]] && kill $writer_pid 2>/dev/null
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	rm -f $TEST_BASE_DIR/clonedup_shadow \
	    $TEST_BASE_DIR/clonedup_blk $TEST_BASE_DIR/clonedup_stop
	clonedup_cleanup
}

log_assert "concurrent writes to a destination are never lost"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG

clonedup_pool_create
typeset nblk=64
clonedup_write /$TESTPOOL/a $nblk
clonedup_dup /$TESTPOOL/a /$TESTPOOL/w
log_must cp /$TESTPOOL/w $TEST_BASE_DIR/clonedup_shadow
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 100
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG 4

rm -f $TEST_BASE_DIR/clonedup_stop
(
	typeset i=0
	while [[ ! -f $TEST_BASE_DIR/clonedup_stop ]] &&
	    kill -0 $$ 2>/dev/null; do
		dd if=/dev/urandom of=$TEST_BASE_DIR/clonedup_blk \
		    bs=$CD_BS count=1 status=none
		dd if=$TEST_BASE_DIR/clonedup_blk of=/$TESTPOOL/w \
		    bs=$CD_BS seek=$((i % nblk)) conv=notrunc \
		    status=none
		dd if=$TEST_BASE_DIR/clonedup_blk \
		    of=$TEST_BASE_DIR/clonedup_shadow bs=$CD_BS \
		    seek=$((i % nblk)) conv=notrunc status=none
		i=$((i + 1))
		sleep 0.05
	done
) &
writer_pid=$!

clonedup_run
log_must touch $TEST_BASE_DIR/clonedup_stop
wait $writer_pid
writer_pid=""
clonedup_sync

log_must cmp /$TESTPOOL/w $TEST_BASE_DIR/clonedup_shadow
clonedup_stat_is $CDS_ERRORS 0

# The writer rewrites the destination for the whole run, so the race
# decides how many clones the apply wins, and declining every one is
# correct.  What has to hold is that the apply reached the
# duplicates at all.  An apply that does nothing leaves applied,
# dirty and stale all at zero.  A checksum match over different
# bytes is a real defect, so differs stays pinned at zero.
#
# Not CDS_CANDIDATES.  That counts blocks which reached a batch and
# survived the verify, so a block the writer dirtied first is never
# one, and a run that declines all of them reports zero.
clonedup_stat_is $CDS_SKIP_DIFFERS 0
clonedup_stat_is $CDS_SKIP_BUSY 0
clonedup_stat_is $CDS_SKIP_POLICY 0
typeset ok=$(clonedup_stat $CDS_APPLIED)
typeset dirty=$(clonedup_stat $CDS_SKIP_DIRTY)
typeset stale=$(clonedup_stat $CDS_SKIP_STALE)
log_note "applied $ok dirty $dirty stale $stale"
log_must [ $((ok + dirty + stale)) -gt 0 ]
clonedup_leakcheck

log_pass "concurrent writes to a destination are never lost"
