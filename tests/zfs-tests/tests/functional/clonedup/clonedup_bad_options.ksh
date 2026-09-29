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
#	Conflicting or incomplete command lines are rejected.
#

verify_runnable "global"

log_assert "zpool clonedup rejects bad option combinations"
log_onexit clonedup_cleanup

clonedup_pool_create

log_mustnot zpool clonedup -f -q $TESTPOOL
log_mustnot zpool clonedup -s -p $TESTPOOL
log_mustnot zpool clonedup -w -s $TESTPOOL
log_mustnot zpool clonedup -w -p $TESTPOOL
log_mustnot zpool clonedup -n -s $TESTPOOL
log_mustnot zpool clonedup -f -p $TESTPOOL
log_mustnot zpool clonedup -x $TESTPOOL
log_mustnot zpool clonedup
log_mustnot zpool clonedup nonexistent-pool
log_mustnot eval "zdb -dddd $TESTPOOL 1 | grep -q clonedup_scan"

log_pass "zpool clonedup rejects bad option combinations"
