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
#	A source file truncated while the apply runs is skipped, not
#	read past its new end.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	clonedup_cleanup
}

log_assert "a source truncated during the apply is skipped"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG

clonedup_pool_create
typeset nblk=64
clonedup_write /$TESTPOOL/a $nblk
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
log_must zfs create $TESTPOOL/keep
clonedup_write /$TESTPOOL/keep/x $nblk
clonedup_dup /$TESTPOOL/keep/x /$TESTPOOL/keep/y
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 200
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG 4

log_must zpool clonedup $TESTPOOL
clonedup_wait_applying

#
# Shrink the oldest copy, which is the survivor the apply reads from,
# to one block smaller than the recordsize.  Every block the scan
# indexed above the new end is now past the end of the object.
#
log_must truncate -s 4096 /$TESTPOOL/a
clonedup_sync

log_must zpool wait -t clonedup $TESTPOOL
clonedup_stat_is $CDS_ERRORS 0
clonedup_stat_is $CDS_STATE $DSS_FINISHED
log_must zpool status $TESTPOOL

# the untouched pair still applies, so the run did work rather than
# giving up when the truncated source went away
clonedup_stat_gt $CDS_APPLIED 0
log_must [ $(stat_size /$TESTPOOL/a) -eq 4096 ]
clonedup_leakcheck

log_pass "a source truncated during the apply is skipped"
