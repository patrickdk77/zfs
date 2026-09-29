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
#	A second run indexes only blocks written since the first one
#	and still matches them against the older data.  A run with
#	nothing new indexes nothing.
#

verify_runnable "global"

log_assert "incremental runs index new blocks and match old ones"
log_onexit clonedup_cleanup

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_sync
clonedup_run
typeset txg1=$(clonedup_last_txg)
clonedup_stat_is $CDS_APPLIED 0

clonedup_dup /$TESTPOOL/a /$TESTPOOL/c
clonedup_sync
clonedup_run
clonedup_stat_is $CDS_INDEXED $CD_BLOCKS
clonedup_stat_is $CDS_GROUPS $CD_BLOCKS
clonedup_stat_is $CDS_CANDIDATES $CD_BLOCKS
clonedup_stat_is $CDS_APPLIED $CD_BLOCKS
clonedup_check_shared $TESTPOOL a $TESTPOOL c "$(clonedup_all_blocks)"
log_must [ $(clonedup_last_txg) -gt $txg1 ]

clonedup_run
clonedup_stat_is $CDS_INDEXED 0
clonedup_stat_is $CDS_APPLIED 0
log_must eval \
    "zpool status $TESTPOOL | grep -q 'completed: 0 blocks cloned'"
clonedup_leakcheck

log_pass "incremental runs index new blocks and match old ones"
