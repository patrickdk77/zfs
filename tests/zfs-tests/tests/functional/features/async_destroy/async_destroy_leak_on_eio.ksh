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

# DESCRIPTION
# A pool can still be exported after zfs_free_leak_on_eio moves space
# that an async destroy could not free to $LEAK.
#
# STRATEGY
# 1. Create a pool on a file and write a 64 MiB file with 128K
#    records, so that one L1 block points to all of its data.
# 2. Export and import the pool, so the L1 block is read from disk,
#    and inject EIO on it under the bookmark of a destroyed objset.
# 3. Set zfs_free_leak_on_eio, destroy the dataset and wait for the
#    free.  The async destroy cannot read the L1 block, so it leaks
#    the file's data and creates $LEAK.
# 4. Check that leaked is not 0, then export and import the pool.

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

function cleanup
{
	zinject -c all
	log_must restore_tunable FREE_LEAK_ON_EIO
	poolexists $TESTPOOL2 && zpool destroy -f $TESTPOOL2
	rm -f $VDEV
}

VDEV=$TEST_BASE_DIR/leakdev
log_onexit cleanup
log_must save_tunable FREE_LEAK_ON_EIO

log_must truncate -s 512m $VDEV
log_must zpool create -O compression=off -O recordsize=128k \
    $TESTPOOL2 $VDEV
log_must zfs create $TESTPOOL2/fs
log_must file_write -o create -f /$TESTPOOL2/fs/file -b 1048576 \
    -c 64 -d R
obj=$(get_objnum /$TESTPOOL2/fs/file)
log_must zpool export $TESTPOOL2
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL2

log_must zinject -b ffffffffffffffff:$(printf %x $obj):1:0 -e io \
    $TESTPOOL2
log_must set_tunable32 FREE_LEAK_ON_EIO 1
log_must zfs destroy $TESTPOOL2/fs
log_must zpool wait -t free $TESTPOOL2
log_must zinject -c all

leaked=$(get_pool_prop leaked $TESTPOOL2)
log_note "the destroy leaked $leaked bytes"
[[ $leaked != 0 ]] || log_fail "the destroy leaked nothing, so the" \
    "injection missed the L1 block"

log_must zpool export $TESTPOOL2
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL2

log_pass "A pool exports after zfs_free_leak_on_eio leaks space."
