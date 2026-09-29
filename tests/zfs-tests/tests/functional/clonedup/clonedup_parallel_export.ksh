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
#	With several apply workers, a plain run ends within a bound,
#	and so does an export, whether it comes after the run or in
#	the middle of its apply.  After the export during the apply,
#	the import restarts the run and it finishes.
#

verify_runnable "global"

typeset -i nblk=16
typeset -i hold_ms=250
typeset -i bound=120

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_TXG_DELAY
	log_must restore_tunable CLONEDUP_APPLY_THREADS
	clonedup_cleanup
}

log_assert "a run with several workers ends and the pool exports"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_TXG_DELAY
log_must save_tunable CLONEDUP_APPLY_THREADS

clonedup_pool_create
clonedup_write /$TESTPOOL/a $nblk
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_THREADS 2
log_must set_tunable32 CLONEDUP_APPLY_TXG_DELAY $hold_ms

clonedup_bounded $bound zpool clonedup -w $TESTPOOL
clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_check_shared $TESTPOOL a $TESTPOOL b \
    "$(clonedup_all_blocks $nblk)"

clonedup_bounded $bound zpool export $TESTPOOL
clonedup_bounded $bound zpool import $TESTPOOL

# New duplicates for a run to be exported out from under.
clonedup_write /$TESTPOOL/c $nblk
clonedup_dup /$TESTPOOL/c /$TESTPOOL/d
clonedup_sync

log_must zpool clonedup $TESTPOOL
clonedup_wait_applying
clonedup_wait_apply_done 2
clonedup_bounded $bound zpool export $TESTPOOL
clonedup_bounded $bound zpool import $TESTPOOL
clonedup_bounded $bound zpool wait -t clonedup $TESTPOOL
clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_stat_is $CDS_ERRORS 0
clonedup_check_shared $TESTPOOL c $TESTPOOL d \
    "$(clonedup_all_blocks $nblk)"
log_must cmp /$TESTPOOL/c /$TESTPOOL/d
clonedup_leakcheck

log_pass "a run with several workers ends and the pool exports"
