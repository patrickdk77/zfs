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
#	With a collision-resistant checksum and the trust tunable
#	set, a match is cloned without reading either block.  Without
#	the tunable every candidate costs two reads.  The kstat counts
#	both.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TRUST_CHECKSUM
	clonedup_cleanup
}

log_assert "verify reads are counted and skipped only when trusted"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TRUST_CHECKSUM

clonedup_pool_create -O checksum=sha256
typeset all="$(clonedup_all_blocks)"

clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TRUST_CHECKSUM 1
clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL b "$all"
clonedup_kstat_is verify_reads 0
clonedup_kstat_is clones $CD_BLOCKS

clonedup_write /$TESTPOOL/c
clonedup_dup /$TESTPOOL/c /$TESTPOOL/d
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_TRUST_CHECKSUM 0
clonedup_run
clonedup_check_shared $TESTPOOL c $TESTPOOL d "$all"
clonedup_kstat_is verify_reads $((2 * CD_BLOCKS))
clonedup_kstat_is verify_bytes $((2 * CD_BLOCKS * CD_BS))
clonedup_kstat_is clones $((2 * CD_BLOCKS))
clonedup_kstat_gt dst_mounted 0
clonedup_kstat_is dst_owned 0
clonedup_kstat_is dst_zvol 0
clonedup_leakcheck

log_pass "verify reads are counted and skipped only when trusted"
