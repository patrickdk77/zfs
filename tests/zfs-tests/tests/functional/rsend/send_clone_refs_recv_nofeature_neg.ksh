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
# have the block_cloning feature enabled, by any pool while
# zfs_bclone_enabled is 0, and by a corrective receive.  Each failure
# is clean.
#
# STRATEGY:
# 1. Create a pool with feature@block_cloning=disabled.
# 2. Send a snapshot with shared blocks using -k.
# 3. zfs recv into the new pool must fail.
# 4. The same stream sent without -k receives there.
# 5. With zfs_bclone_enabled=0, zfs recv of the -k stream into a pool
#    with block_cloning fails.
# 6. Receive the stream without -k there; zfs recv -c of the -k
#    stream into that copy fails, and of the plain stream succeeds.
#

verify_runnable "global"

function cleanup
{
	restore_tunable BCLONE_ENABLED
	destroy_pool $TESTPOOL1
	destroy_dataset $POOL/cf -r
	destroy_dataset $POOL2/cf -r
	rm -f $BACKDIR/cf-c $BACKDIR/cf-plain $TESTDIR/vdev_nocl
}

log_assert "a CLONE stream is refused without block_cloning enabled"
log_onexit cleanup

typeset src=$POOL/cf

log_must truncate -s $MINVDEVSIZE $TESTDIR/vdev_nocl
log_must zpool create -f -o feature@block_cloning=disabled \
    $TESTPOOL1 $TESTDIR/vdev_nocl

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must file_write -o create -f $mnt/file1 -b 131072 -c 4 -d R
log_must sync_pool $POOL
log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@s

log_must eval "zfs send -k $src@s > $BACKDIR/cf-c"
log_must stream_has_features $BACKDIR/cf-c clones
log_mustnot eval "zfs recv $TESTPOOL1/cf < $BACKDIR/cf-c"
log_mustnot datasetexists $TESTPOOL1/cf

log_must eval "zfs send $src@s > $BACKDIR/cf-plain"
log_must eval "zfs recv $TESTPOOL1/cf < $BACKDIR/cf-plain"
typeset dmnt=$(get_prop mountpoint $TESTPOOL1/cf)
log_must have_same_content $mnt/file2 $dmnt/file2

log_must save_tunable BCLONE_ENABLED
log_must set_tunable32 BCLONE_ENABLED 0
log_mustnot eval "zfs recv $POOL2/cf < $BACKDIR/cf-c"
log_mustnot datasetexists $POOL2/cf
log_must restore_tunable BCLONE_ENABLED

log_must eval "zfs recv $POOL2/cf < $BACKDIR/cf-plain"
log_mustnot eval "zfs recv -c $POOL2/cf@s < $BACKDIR/cf-c"
log_must eval "zfs recv -c $POOL2/cf@s < $BACKDIR/cf-plain"

log_pass "a CLONE stream is refused without block_cloning enabled"
