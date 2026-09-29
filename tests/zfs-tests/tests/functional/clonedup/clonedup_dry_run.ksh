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
#	A dry run counts what it would clone, clones nothing, writes
#	nothing to the pool, and does not advance last_clonedup_txg,
#	so a real run afterwards still finds the duplicates.
#

verify_runnable "global"

log_assert "zpool clonedup -n reports without cloning or writing"
log_onexit clonedup_cleanup

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

clonedup_run -n

clonedup_check_shared $TESTPOOL a $TESTPOOL b ""
log_must [ "$(clonedup_jstat clonedup_candidates)" -eq $CD_BLOCKS ]
log_must [ "$(clonedup_jstat clonedup_applied)" -eq $CD_BLOCKS ]
log_must eval "zpool status -j $TESTPOOL | grep -q '\"dry_run\":true'"
log_must [ $(clonedup_last_txg) -eq 0 ]
log_must [ $(zpool get -Hpo value bcloneused $TESTPOOL) -eq 0 ]
log_must eval "zpool status $TESTPOOL | grep -q 'dry run completed'"
log_must eval \
    "zpool status -j $TESTPOOL | grep -q '\"state\":\"FINISHED\"'"

# the pool is exactly as the run found it
log_must [ "$(get_pool_prop feature@clonedup $TESTPOOL)" = "enabled" ]
log_mustnot eval "zdb -dddd $TESTPOOL 1 | grep -q clonedup_scan"
log_mustnot eval \
    "zdb -dddd $TESTPOOL 1 | grep -qE '^[[:space:]]+scan = '"
log_must [ "$(zpool history $TESTPOOL | grep -c 'zpool clonedup')" \
    -eq 0 ]
log_must [ "$(zpool history -i $TESTPOOL | grep -c 'scan setup')" \
    -eq 0 ]

# in memory only, so an import finds no run to report or resume
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
log_mustnot eval "zpool status $TESTPOOL | grep -q clonedup"

clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL b "$(clonedup_all_blocks)"
log_must [ $(clonedup_last_txg) -gt 0 ]
clonedup_leakcheck

log_pass "zpool clonedup -n reports without cloning or writing"
