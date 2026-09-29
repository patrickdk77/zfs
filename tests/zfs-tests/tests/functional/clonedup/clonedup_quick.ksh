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
#	-q clones duplicates among new blocks only.  New copies of old
#	data are left for a default run.
#

verify_runnable "global"

log_assert "zpool clonedup -q matches new data against itself only"
log_onexit clonedup_cleanup

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_sync
clonedup_run
typeset txg1=$(clonedup_last_txg)

clonedup_dup /$TESTPOOL/a /$TESTPOOL/d
clonedup_write /$TESTPOOL/e
clonedup_dup /$TESTPOOL/e /$TESTPOOL/f
clonedup_sync

clonedup_run -q
clonedup_check_shared $TESTPOOL e $TESTPOOL f "$(clonedup_all_blocks)"
clonedup_check_shared $TESTPOOL a $TESTPOOL d ""
log_must [ $(( $(clonedup_stat $CDS_FLAGS) & DSF_CLONEDUP_QUICK )) \
    -ne 0 ]
log_must [ $(clonedup_last_txg) -eq $txg1 ]

clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL d "$(clonedup_all_blocks)"
log_must [ $(clonedup_last_txg) -gt $txg1 ]
clonedup_leakcheck

log_pass "zpool clonedup -q matches new data against itself only"
