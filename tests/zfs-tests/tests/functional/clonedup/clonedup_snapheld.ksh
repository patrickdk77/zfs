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
#	A block held by a snapshot is the surviving copy.  A live
#	file's block that a snapshot also holds is redirected when
#	zfs_clonedup_apply_snapheld is set and left alone when it is
#	not.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_SNAPHELD
	clonedup_cleanup
}

log_assert "snapshot-held blocks are sources, heads are redirected"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_SNAPHELD
log_must set_tunable32 CLONEDUP_APPLY_SNAPHELD 1

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_sync
log_must zfs snapshot $TESTPOOL@s1

# a is held by s1: g must be redirected onto a, never the reverse.
clonedup_dup /$TESTPOOL/a /$TESTPOOL/g
clonedup_sync
clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL g "$(clonedup_all_blocks)"
clonedup_check_shared $TESTPOOL@s1 a $TESTPOOL a \
    "$(clonedup_all_blocks)"

# h is held by s2 as well: the head copy is redirected, s2 keeps it.
clonedup_dup /$TESTPOOL/a /$TESTPOOL/h
clonedup_sync
log_must zfs snapshot $TESTPOOL@s2
clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL h "$(clonedup_all_blocks)"
clonedup_check_shared $TESTPOOL@s2 h $TESTPOOL h ""
clonedup_stat_is $CDS_SAVED_SNAPHELD \
    $((CD_BLOCKS * $(clonedup_blk_asize $TESTPOOL a)))
# zpool status -j reports the same saved total as the plain output.
typeset -i saved_total=$(( $(clonedup_stat $CDS_SAVED) +
    $(clonedup_stat $CDS_SAVED_SNAPHELD) ))
log_must [ "$(clonedup_jstat clonedup_saved)" -eq $saved_total ]
typeset alloc_before=$(zpool get -Hpo value allocated $TESTPOOL)
log_must zfs destroy $TESTPOOL@s2
clonedup_sync
log_must [ $(zpool get -Hpo value allocated $TESTPOOL) \
    -lt $alloc_before ]

# With the policy off a held head block is skipped.
log_must set_tunable32 CLONEDUP_APPLY_SNAPHELD 0
clonedup_dup /$TESTPOOL/a /$TESTPOOL/i
clonedup_sync
log_must zfs snapshot $TESTPOOL@s3
clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL i ""
clonedup_stat_gt $CDS_SKIP_POLICY 0
clonedup_leakcheck

log_pass "snapshot-held blocks are sources, heads are redirected"
