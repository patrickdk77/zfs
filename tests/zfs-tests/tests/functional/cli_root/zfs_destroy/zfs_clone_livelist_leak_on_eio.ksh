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
# With zfs_free_leak_on_eio set, a destroyed clone's space must stay
# in $FREE while its livelist is deleted, and must not move to $LEAK.
# Space that an async destroy could not free must move to $LEAK when
# the async destroy ends, even while a livelist delete is pending.
# $FREE must then drop to 0 when the delete ends, even if the tunable
# was cleared in between.
#
# STRATEGY
# 1. Set zfs_free_leak_on_eio and write to a clone in 24 txgs, so its
#    livelist has a sublist for most of them.
# 2. Export and import the pool, and sync a few txgs, since background
#    work waits zfs_import_defer_txgs after an import. Then delay
#    every read by a second, so the delete thread is still reading
#    sublists when zfs destroy returns.
# 3. Destroy the clone. Check that leaked has not grown and freeing
#    is not 0, then that once the free finishes, leaked is unchanged
#    and freeing is 0.
# 4. Repeat with a scrub running, which keeps dsl_scan_active() true
#    by itself.
# 5. Create a pool on a file. Write a 64 MiB file with 128K records
#    to a dataset, so that one L1 block points to all of its data,
#    and set up a clone as in step 1. Export and import the pool,
#    inject EIO on the L1 block under the bookmark of a destroyed
#    objset, and delay every read.
# 6. Destroy the clone, then the dataset. Once the dataset's async
#    destroy ends, check that the livelist delete is still running,
#    that leaked grew by at least the file's size and at most the
#    dataset's used space, and that freeing is still above 0. The
#    lower bound shows that the async destroy hit the injected error,
#    and the upper bound that the clone's space stayed in $FREE.
# 7. Clear zfs_free_leak_on_eio while the livelist delete still runs,
#    and wait for the free to finish. Check that freeing is 0 and
#    that leaked has not changed since the async destroy ended.

. $STF_SUITE/include/libtest.shlib
DESTROY_DIR=$STF_SUITE/tests/functional/cli_root/zfs_destroy
. $DESTROY_DIR/zfs_destroy_common.kshlib

verify_runnable "global"

function cleanup
{
	typeset t failed=""

	zinject -c all
	if poolexists $TESTPOOL2; then
		log_must_retry "busy" 5 zpool destroy -f \
		    $TESTPOOL2 || failed+=" zpool-destroy"
	fi
	poolexists $TESTPOOL2 || rm -f $VDEV
	poolexists $TESTPOOL || zpool import $TESTPOOL
	zpool scrub -s $TESTPOOL
	zpool wait -t free $TESTPOOL
	if datasetexists $TESTPOOL/$TESTFS1; then
		log_must_retry "busy" 5 zfs destroy -R \
		    $TESTPOOL/$TESTFS1 || failed+=" zfs-destroy"
	fi
	for t in SCAN_SUSPEND_PROGRESS FREE_LEAK_ON_EIO \
	    LIVELIST_MAX_ENTRIES LIVELIST_MIN_PERCENT_SHARED; do
		restore_tunable $t || failed+=" restore-$t"
	done
	[[ -z $failed ]] || log_fail "cleanup steps failed:$failed"
}

function create_clone # pool
{
	typeset pool=$1
	typeset i sublists

	log_must zfs clone -o compression=off -o recordsize=128k \
	    $pool/$TESTFS1@snap $pool/$TESTCLONE
	for i in {1..24}; do
		log_must mkfile 1m /$pool/$TESTCLONE/file$i
		sync_pool $pool
	done
	sublists=$(zdb -vvvvv $pool/$TESTCLONE | \
	    awk '/Livelist:/ { print $(NF - 1) }')
	(( sublists >= 20 )) || log_fail "clone has" \
	    "${sublists:-no} livelist sublists, want 20+"
}

function destroy_clone # case
{
	typeset i leaked0 leaked freeing

	create_clone $TESTPOOL
	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	if [[ $1 == "scrub running" ]]; then
		log_must zpool scrub $TESTPOOL
		is_pool_scrubbing $TESTPOOL || \
		    log_fail "no scrub is running"
	fi
	for i in {1..3}; do
		sync_pool $TESTPOOL
	done
	log_must zinject -d $DISK -D 1000:4 -T read $TESTPOOL

	leaked0=$(get_pool_prop leaked $TESTPOOL)
	log_must zfs destroy $TESTPOOL/$TESTCLONE
	leaked=$(get_pool_prop leaked $TESTPOOL)
	freeing=$(get_pool_prop freeing $TESTPOOL)
	log_must zinject -c all
	log_note "$1: during the delete, leaked $leaked" \
	    "(was $leaked0), freeing $freeing"
	[[ $leaked == "$leaked0" ]] || \
	    log_fail "$1: leaked went from $leaked0 to $leaked"
	[[ $freeing != 0 ]] || \
	    log_fail "$1: the delete finished before the check"

	check_livelist_gone
	leaked=$(get_pool_prop leaked $TESTPOOL)
	freeing=$(get_pool_prop freeing $TESTPOOL)
	log_note "$1: after the delete, leaked $leaked," \
	    "freeing $freeing"
	[[ $leaked == "$leaked0" && $freeing == 0 ]] || \
	    log_fail "$1: pool leaked $leaked and is freeing $freeing"
}

function destroy_clone_and_leak
{
	typeset pool=$TESTPOOL2
	typeset i obj used state leaked0 leaked1 leaked freeing
	typeset livelist
	typeset -i n growth

	rm -f $VDEV
	log_must truncate -s 512m $VDEV
	log_must zpool create -O compression=off -O recordsize=128k \
	    $pool $VDEV
	log_must zfs create $pool/$TESTFS1
	log_must zfs snapshot $pool/$TESTFS1@snap
	log_must zfs create $pool/$TESTFS2
	log_must file_write -o create -f /$pool/$TESTFS2/file \
	    -b 1048576 -c $((FILE_SIZE / 1048576)) -d R
	obj=$(get_objnum /$pool/$TESTFS2/file)
	create_clone $pool

	log_must_busy zpool export $pool
	log_must zpool import -d $TEST_BASE_DIR $pool
	for i in {1..3}; do
		sync_pool $pool
	done
	used=$(get_prop used $pool/$TESTFS2)
	log_must zinject -b ffffffffffffffff:$(printf %x $obj):1:0 \
	    -e io $pool
	log_must zinject -d $VDEV -D 1000:4 -T read $pool

	leaked0=$(get_pool_prop leaked $pool)
	log_must zfs destroy $pool/$TESTCLONE
	log_must zfs destroy $pool/$TESTFS2
	n=0
	state=$(get_pool_prop feature@async_destroy $pool)
	while [[ $state != "enabled" ]]; do
		(( n++ < 120 )) || log_fail "the async destroy did" \
		    "not end in 120 seconds"
		sleep 1
		state=$(get_pool_prop feature@async_destroy $pool)
	done
	leaked1=$(get_pool_prop leaked $pool)
	freeing=$(get_pool_prop freeing $pool)
	livelist=$(get_pool_prop feature@livelist $pool)
	log_note "after the async destroy, leaked $leaked1" \
	    "(was $leaked0), freeing $freeing," \
	    "feature@livelist $livelist"
	[[ $livelist == "active" ]] || log_fail "the livelist" \
	    "delete ended before the async destroy"
	(( growth = leaked1 - leaked0 ))
	(( growth >= FILE_SIZE && growth <= used )) || \
	    log_fail "leaked went from $leaked0 to $leaked1, want" \
	    "growth from $FILE_SIZE to $used"
	(( freeing > 0 )) || log_fail "freeing is $freeing with" \
	    "the livelist delete pending"

	log_must set_tunable32 FREE_LEAK_ON_EIO 0
	livelist=$(get_pool_prop feature@livelist $pool)
	log_must zinject -c all
	[[ $livelist == "active" ]] || log_fail "the livelist" \
	    "delete ended before zfs_free_leak_on_eio was cleared"

	log_must zpool wait -t free $pool
	leaked=$(get_pool_prop leaked $pool)
	freeing=$(get_pool_prop freeing $pool)
	log_note "after the livelist delete, leaked $leaked," \
	    "freeing $freeing"
	[[ $freeing == 0 ]] || log_fail "freeing is still $freeing" \
	    "after the livelist delete"
	[[ $leaked == "$leaked1" ]] || log_fail "leaked went from" \
	    "$leaked1 to $leaked during the livelist delete"
}

DISK=${DISKS%% *}
VDEV=$TEST_BASE_DIR/livelist_leak_dev
((FILE_SIZE = 64 * 1048576))

log_onexit cleanup

log_must zpool wait -t free $TESTPOOL

log_must save_tunable LIVELIST_MIN_PERCENT_SHARED
log_must save_tunable LIVELIST_MAX_ENTRIES
log_must save_tunable FREE_LEAK_ON_EIO
log_must save_tunable SCAN_SUSPEND_PROGRESS
log_must set_tunable32 LIVELIST_MIN_PERCENT_SHARED -1
log_must set_tunable64 LIVELIST_MAX_ENTRIES 4
log_must set_tunable32 FREE_LEAK_ON_EIO 1

log_must zfs create $TESTPOOL/$TESTFS1
log_must zfs snapshot $TESTPOOL/$TESTFS1@snap

destroy_clone "idle"

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
destroy_clone "scrub running"
log_must zpool scrub -s $TESTPOOL

destroy_clone_and_leak

log_pass "Only space an async destroy could not free goes to \$LEAK."
