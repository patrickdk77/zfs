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
#	A stronger run replaces a weaker running one, in the order
#	quick < default < full.  An equal or weaker request is
#	refused.
#

verify_runnable "global"

log_assert "run precedence is quick < default < full"
log_onexit clonedup_cleanup

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_sync

clonedup_hold
log_must zpool clonedup -q $TESTPOOL
clonedup_wait_running
log_must [ $(( $(clonedup_stat $CDS_FLAGS) & DSF_CLONEDUP_QUICK )) \
    -ne 0 ]
log_mustnot zpool clonedup -q $TESTPOOL

log_must zpool clonedup $TESTPOOL
log_must clonedup_is_running
log_must [ $(( $(clonedup_stat $CDS_FLAGS) & DSF_CLONEDUP_QUICK )) \
    -eq 0 ]
log_mustnot zpool clonedup -q $TESTPOOL
log_mustnot zpool clonedup $TESTPOOL

log_must zpool clonedup -f $TESTPOOL
log_must clonedup_is_running
log_must [ $(( $(clonedup_stat $CDS_FLAGS) & DSF_CLONEDUP_FULL )) \
    -ne 0 ]
log_mustnot zpool clonedup -f $TESTPOOL
log_mustnot zpool clonedup $TESTPOOL
log_mustnot zpool clonedup -q $TESTPOOL

clonedup_release
log_must zpool wait -t clonedup $TESTPOOL
clonedup_stat_is $CDS_STATE $DSS_FINISHED

log_pass "run precedence is quick < default < full"
