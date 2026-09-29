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
#	A volume being rewritten while its duplicates are cloned never
#	loses a write.  Every write also goes to a shadow file; after
#	an export and import the volume must match the shadow.
#

verify_runnable "global"

typeset writer_pid=""

function cleanup
{
	exec 3<&-
	[[ -n $writer_pid ]] && kill $writer_pid 2>/dev/null
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	rm -f $TEST_BASE_DIR/clonedup_shadow \
	    $TEST_BASE_DIR/clonedup_blk $TEST_BASE_DIR/clonedup_stop
	clonedup_cleanup
}

log_assert "concurrent writes to a volume are never lost"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG

clonedup_pool_create
typeset nblk=64
typeset nbytes=$((CD_BS * nblk))
clonedup_write /$TESTPOOL/a $nblk
log_must zfs create -V $nbytes -b $CD_BS $TESTPOOL/w
block_device_wait $ZVOL_DEVDIR/$TESTPOOL/w
clonedup_zvol_fill /$TESTPOOL/a $TESTPOOL/w
log_must cp /$TESTPOOL/a $TEST_BASE_DIR/clonedup_shadow
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 100
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG 4

exec 3<> $ZVOL_DEVDIR/$TESTPOOL/w
rm -f $TEST_BASE_DIR/clonedup_stop
(
	typeset i=0
	while [[ ! -f $TEST_BASE_DIR/clonedup_stop ]] &&
	    kill -0 $$ 2>/dev/null; do
		dd if=/dev/urandom of=$TEST_BASE_DIR/clonedup_blk \
		    bs=$CD_BS count=1 status=none
		dd if=$TEST_BASE_DIR/clonedup_blk \
		    of=$ZVOL_DEVDIR/$TESTPOOL/w bs=$CD_BS \
		    seek=$((i % nblk)) conv=notrunc,fsync status=none
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
exec 3<&-
clonedup_sync

# a fresh import drops every cached copy of the volume
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
block_device_wait $ZVOL_DEVDIR/$TESTPOOL/w
log_must dd if=$ZVOL_DEVDIR/$TESTPOOL/w bs=$CD_BS count=$nblk \
    status=none of=$TEST_BASE_DIR/clonedup_blk
log_must cmp $TEST_BASE_DIR/clonedup_blk \
    $TEST_BASE_DIR/clonedup_shadow
clonedup_stat_is $CDS_ERRORS 0
# A writer that dirties every candidate first leaves nothing to
# apply, so APPLIED alone reads zero on a run that behaved.  The
# compare above is what proves no write was lost.
typeset ok=$(clonedup_stat $CDS_APPLIED)
typeset dirty=$(clonedup_stat $CDS_SKIP_DIRTY)
typeset stale=$(clonedup_stat $CDS_SKIP_STALE)
log_note "applied $ok dirty $dirty stale $stale"
log_must [ $((ok + dirty + stale)) -gt 0 ]
clonedup_leakcheck

log_pass "concurrent writes to a volume are never lost"
