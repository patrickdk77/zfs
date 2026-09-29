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
#	A volume destination shrunk by zfs set volsize while the apply
#	runs is skipped.  volsize takes zv_suspend_lock rather than
#	the range lock the apply holds, and frees the blocks past the
#	new end, so the clone would otherwise run past them.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG
	clonedup_cleanup
}

log_assert "a volume shrunk during the apply is skipped"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_BLOCKS_PER_TXG

clonedup_pool_create
typeset nblk=64
typeset nbytes=$((CD_BS * nblk))

clonedup_write /$TESTPOOL/a $nblk
clonedup_sync
log_must zfs create -V $nbytes -b $CD_BS $TESTPOOL/v
block_device_wait $ZVOL_DEVDIR/$TESTPOOL/v
clonedup_zvol_fill /$TESTPOOL/a $TESTPOOL/v
log_must zfs create $TESTPOOL/keep
clonedup_write /$TESTPOOL/keep/x $nblk
clonedup_dup /$TESTPOOL/keep/x /$TESTPOOL/keep/y
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY 200
log_must set_tunable32 CLONEDUP_APPLY_BLOCKS_PER_TXG 4

log_must zpool clonedup $TESTPOOL
clonedup_wait_applying

log_must zfs set volsize=$CD_BS $TESTPOOL/v
clonedup_sync

log_must zpool wait -t clonedup $TESTPOOL
clonedup_stat_is $CDS_ERRORS 0
clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_stat_gt $CDS_APPLIED 0
log_must [ $(zfs get -Hpo value volsize $TESTPOOL/v) -eq $CD_BS ]
clonedup_leakcheck

log_pass "a volume shrunk during the apply is skipped"
