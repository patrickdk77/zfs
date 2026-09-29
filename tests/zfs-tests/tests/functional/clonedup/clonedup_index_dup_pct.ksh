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
#	zfs_clonedup_index_dup_pct lets a first run plan a counting
#	pre-pass.  A first run has no measured block count, so it
#	estimates one from the pool's allocated space.
#
# STRATEGY:
#	1. Write enough that the index needs several partitions at the
#	   cap, the shape where a pre-pass pays.
#	2. On auto, with the expected duplication set, the first run
#	   takes the pre-pass.
#	3. The blocks are shared either way.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_INDEX_FILTER
	log_must restore_tunable CLONEDUP_INDEX_DUP_PCT
	log_must restore_tunable CLONEDUP_SCAN_MEM_MAX
	clonedup_cleanup
}

log_assert "a first run plans its pre-pass from index_dup_pct"
log_onexit cleanup

log_must save_tunable CLONEDUP_INDEX_FILTER
log_must save_tunable CLONEDUP_INDEX_DUP_PCT
log_must save_tunable CLONEDUP_SCAN_MEM_MAX

clonedup_pool_create
clonedup_write /$TESTPOOL/a 128
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

log_must set_tunable32 CLONEDUP_INDEX_FILTER 2
log_must set_tunable32 CLONEDUP_INDEX_DUP_PCT 10
log_must set_tunable64 CLONEDUP_SCAN_MEM_MAX $((32 * 1024))

clonedup_run
clonedup_kstat_is count_walks 1
clonedup_stat_gt $CDS_FILTER_SLOTS 0
clonedup_check_shared $TESTPOOL a $TESTPOOL b \
    "$(clonedup_all_blocks 128)"
clonedup_stat_is $CDS_ERRORS 0
clonedup_leakcheck

log_pass "a first run plans its pre-pass from index_dup_pct"
