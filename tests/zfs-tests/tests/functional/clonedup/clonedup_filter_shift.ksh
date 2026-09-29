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
#	zfs_clonedup_index_filter_shift sets the slot count of the
#	counting pre-pass.  A value past the largest count the pass
#	can hold is taken as that largest, and then held to the memory
#	cap like any other.
#
# STRATEGY:
#	1. Force the pre-pass and cap the index at 1 MiB.
#	2. Run with the shift at 20: the pass has 2^20 slots, and
#	   while it is held, zpool status names the counting pass.
#	3. Run with the shift at 64: the pass has the 2^22 slots that
#	   fill the cap, rather than none.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_INDEX_FILTER
	log_must restore_tunable CLONEDUP_INDEX_FILTER_SHIFT
	log_must restore_tunable CLONEDUP_SCAN_MEM_MAX
	clonedup_cleanup
}

log_assert "an oversized filter shift is held to the largest filter"
log_onexit cleanup

log_must save_tunable CLONEDUP_INDEX_FILTER
log_must save_tunable CLONEDUP_INDEX_FILTER_SHIFT
log_must save_tunable CLONEDUP_SCAN_MEM_MAX

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

log_must set_tunable32 CLONEDUP_INDEX_FILTER 1
log_must set_tunable64 CLONEDUP_SCAN_MEM_MAX $((1024 * 1024))

log_must set_tunable32 CLONEDUP_INDEX_FILTER_SHIFT 20
clonedup_hold
log_must zpool clonedup -f $TESTPOOL
clonedup_wait_running
log_must eval "zpool status $TESTPOOL |" \
    "grep -q 'counting new data, partition 1 of 1: '"
clonedup_release
log_must zpool wait -t clonedup $TESTPOOL
clonedup_kstat_is count_walks 1
clonedup_stat_is $CDS_FILTER_SLOTS $((1 << 20))
clonedup_check_shared $TESTPOOL a $TESTPOOL b "$(clonedup_all_blocks)"

log_must set_tunable32 CLONEDUP_INDEX_FILTER_SHIFT 64
clonedup_run -f
clonedup_stat_is $CDS_FILTER_SLOTS $((1 << 22))
clonedup_check_shared $TESTPOOL a $TESTPOOL b "$(clonedup_all_blocks)"
clonedup_stat_is $CDS_ERRORS 0
clonedup_leakcheck

log_pass "an oversized filter shift is held to the largest filter"
