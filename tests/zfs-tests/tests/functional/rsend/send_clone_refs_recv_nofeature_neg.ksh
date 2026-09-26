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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/rsend/rsend.kshlib
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
# A stream carrying CLONE records is rejected by a pool that does not
# have the block_cloning feature enabled, and the failure is clean.
#
# STRATEGY:
# 1. Create a pool with feature@block_cloning=disabled.
# 2. Send a snapshot with shared blocks using -k.
# 3. zfs recv into the new pool must fail.
# 4. The same stream sent without -k receives there.
#

verify_runnable "global"

function cleanup
{
	destroy_pool pool_nocl
	destroy_dataset $POOL/cf -r
	rm -f $BACKDIR/cf-c $BACKDIR/cf-plain $TESTDIR/vdev_nocl
}

log_assert "a CLONE stream is refused without block_cloning enabled"
log_onexit cleanup

typeset src=$POOL/cf

log_must truncate -s $MINVDEVSIZE $TESTDIR/vdev_nocl
log_must zpool create -f -o feature@block_cloning=disabled pool_nocl \
    $TESTDIR/vdev_nocl

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@s

log_must eval "zfs send -k $src@s > $BACKDIR/cf-c"
log_must stream_has_features $BACKDIR/cf-c clones
log_mustnot eval "zfs recv pool_nocl/cf < $BACKDIR/cf-c"
log_mustnot datasetexists pool_nocl/cf

log_must eval "zfs send $src@s > $BACKDIR/cf-plain"
log_must eval "zfs recv pool_nocl/cf < $BACKDIR/cf-plain"
typeset dmnt=$(get_prop mountpoint pool_nocl/cf)
log_must have_same_content $mnt/file2 $dmnt/file2

log_pass "a CLONE stream is refused without block_cloning enabled"
