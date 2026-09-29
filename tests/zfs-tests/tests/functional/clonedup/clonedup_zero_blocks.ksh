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
#	All-zero blocks become holes by default, the surviving copy
#	included, are cloned in mode 1 and left alone in mode 2.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_ZERO_BLOCKS
	clonedup_cleanup
}

log_assert \
    "all-zero blocks are handled per zfs_clonedup_apply_zero_blocks"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_ZERO_BLOCKS

clonedup_pool_create
log_must dd if=/dev/zero of=/$TESTPOOL/z1 bs=$CD_BS count=$CD_BLOCKS \
    status=none
log_must dd if=/dev/zero of=/$TESTPOOL/z2 bs=$CD_BS count=$CD_BLOCKS \
    status=none
clonedup_sync
log_must [ $(du -k /$TESTPOOL/z1 | cut -f1) -gt 512 ]

log_must set_tunable32 CLONEDUP_APPLY_ZERO_BLOCKS 0
clonedup_run
clonedup_sync
log_must [ $(du -k /$TESTPOOL/z1 | cut -f1) -lt 64 ]
log_must [ $(du -k /$TESTPOOL/z2 | cut -f1) -lt 64 ]
log_must [ $(zpool get -Hpo value bcloneused $TESTPOOL) -eq 0 ]
log_must cmp /$TESTPOOL/z1 /$TESTPOOL/z2
log_must [ $(stat_size /$TESTPOOL/z1) -eq $((CD_BLOCKS * CD_BS)) ]

log_must dd if=/dev/zero of=/$TESTPOOL/z3 bs=$CD_BS count=$CD_BLOCKS \
    status=none
log_must dd if=/dev/zero of=/$TESTPOOL/z4 bs=$CD_BS count=$CD_BLOCKS \
    status=none
clonedup_sync
log_must set_tunable32 CLONEDUP_APPLY_ZERO_BLOCKS 1
clonedup_run
clonedup_check_shared $TESTPOOL z3 $TESTPOOL z4 \
    "$(clonedup_all_blocks)"

log_must dd if=/dev/zero of=/$TESTPOOL/z5 bs=$CD_BS count=$CD_BLOCKS \
    status=none
log_must dd if=/dev/zero of=/$TESTPOOL/z6 bs=$CD_BS count=$CD_BLOCKS \
    status=none
clonedup_sync
log_must set_tunable32 CLONEDUP_APPLY_ZERO_BLOCKS 2
clonedup_run
clonedup_check_shared $TESTPOOL z5 $TESTPOOL z6 ""
clonedup_stat_gt $CDS_SKIP_POLICY 0
clonedup_leakcheck

log_pass \
    "all-zero blocks are handled per zfs_clonedup_apply_zero_blocks"
