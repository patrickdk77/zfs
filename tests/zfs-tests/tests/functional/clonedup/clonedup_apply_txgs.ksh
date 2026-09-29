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
#	The apply phase does not spin empty transaction groups.  The
#	sync thread skips its timeout while a scan is active, so an
#	apply with nothing to do each group would sync about a
#	hundred empty groups a second, each writing its own overhead.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_ENABLED
	clonedup_cleanup
}

function txg_open
{
	awk 'NR > 1 { t = $1 } END { print t }' \
	    /proc/spl/kstat/zfs/$TESTPOOL/txgs
}

log_assert \
    "the apply phase syncs transaction groups at the normal cadence"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_ENABLED

clonedup_pool_create
clonedup_write /$TESTPOOL/a 64
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

# park the run in its apply phase with nothing to do
log_must set_tunable32 CLONEDUP_APPLY_ENABLED 0
log_must zpool clonedup -n $TESTPOOL
clonedup_wait_applying

typeset before=$(txg_open)
sleep 10
typeset after=$(txg_open)
log_note "$((after - before)) transaction groups opened in 10 seconds"
log_must [ $((after - before)) -le 4 ]

log_must zpool clonedup -s $TESTPOOL
log_mustnot clonedup_is_running

log_pass \
    "the apply phase syncs transaction groups at the normal cadence"
