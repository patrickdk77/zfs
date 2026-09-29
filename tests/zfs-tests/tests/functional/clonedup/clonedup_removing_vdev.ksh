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
. $STF_SUITE/tests/functional/removal/removal.kshlib

#
# DESCRIPTION:
#	Blocks on a device that is being removed, and blocks that a
#	finished removal left on an indirect device, are never cloned
#	in either direction.  Blocks written elsewhere still are.
#

verify_runnable "global"

function cleanup
{
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0
	clonedup_cleanup
}

log_assert "blocks on a removing or indirect device are left alone"
log_onexit cleanup

set -A disks $DISKS
(( ${#disks[@]} >= 2 )) || log_unsupported "needs two disks"
typeset all="$(clonedup_all_blocks)"

log_must zpool create -f -o feature@clonedup=enabled \
    -O compression=off -O xattr=sa $TESTPOOL ${disks[0]}
clonedup_write /$TESTPOOL/a
clonedup_sync
log_must zpool add -f $TESTPOOL ${disks[1]}
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1
log_must zpool remove $TESTPOOL ${disks[0]}
clonedup_run
clonedup_check_shared $TESTPOOL a $TESTPOOL b ""
clonedup_stat_is $CDS_CANDIDATES 0

log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0
log_must wait_for_removal $TESTPOOL

# a now lives on an indirect device; fresh copies pair up without it
clonedup_dup /$TESTPOOL/a /$TESTPOOL/c
clonedup_dup /$TESTPOOL/a /$TESTPOOL/d
clonedup_sync
clonedup_run -f
clonedup_check_shared $TESTPOOL c $TESTPOOL d "$all"
clonedup_check_shared $TESTPOOL a $TESTPOOL c ""
log_must cmp /$TESTPOOL/a /$TESTPOOL/d
clonedup_leakcheck

log_pass "blocks on a removing or indirect device are left alone"
