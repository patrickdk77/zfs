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
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#
. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/no_space/enospc.cfg

#
# DESCRIPTION:
#	Punching a hole in a file on a full pool succeeds and frees
#	the space.
#
# STRATEGY:
#	1. Write a large file, then fill the pool until no space is
#	   available.
#	2. Punch a hole through the large file.
#	3. Check that the punch succeeds, space is available again,
#	   and a new write succeeds.
#

verify_runnable "global"

log_assert "Punching a hole on a full pool frees its space."

function cleanup
{
	destroy_pool $TESTPOOL
}
log_onexit cleanup

default_setup_noexit $DISK_SMALL
log_must zfs set compression=off $TESTPOOL/$TESTFS

typeset big=$TESTDIR/big

#
# Size the large file from the available space. NUM_WRITES blocks
# of BLOCKSZ do not fit on DISK_SMALL.
#
typeset -i avail=$(get_prop available $TESTPOOL/$TESTFS)
typeset -i bigcount=$(( avail / 3 / BLOCKSZ ))
(( bigcount < 16 )) && bigcount=16
log_must file_write -o create -f $big -b $BLOCKSZ -c $bigcount -d R
#
# Fill until available reads zero. A write can fail with ENOSPC
# while a few KiB remain, and the punch then succeeds even when its
# logging transaction is not marked netfree.
#
typeset -i before=0
for i in $(seq 100); do
	file_write -o create -f $TESTDIR/fill.$i -b $BLOCKSZ \
	    -c $NUM_WRITES -d R
	sync_all_pools true
	before=$(get_prop available $TESTPOOL/$TESTFS)
	(( before == 0 )) && break
done
sync_all_pools true

before=$(get_prop available $TESTPOOL/$TESTFS)
log_note "available before the punch: $before"

(( before == 0 )) || log_fail "the fill left $before bytes free, so" \
    "the punch would not reach a full pool"

#
# Punch rather than truncate. A truncate reaches zfs_freesp() with
# log set to FALSE and never creates the logging transaction.
#
typeset -i bigsz=$(stat_size $big)
log_must fallocate -p -o 0 -l $bigsz $big
sync_all_pools true

typeset -i after=$(get_prop available $TESTPOOL/$TESTFS)
log_note "available after the punch: $after"

if (( after <= before )); then
	log_fail "the punch freed nothing:" \
	    "$before before, $after after"
fi

log_must file_write -o create -f $TESTDIR/after -b $BLOCKSZ -c 1 -d R

log_pass "Punching a hole on a full pool frees its space."
