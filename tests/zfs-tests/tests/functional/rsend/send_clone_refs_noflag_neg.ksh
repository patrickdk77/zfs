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
# A stream carrying CLONE records without the clones feature flag
# is refused, by zstream validate and by zfs recv, so it can never
# clone into a pool that has block_cloning disabled.
#
# STRATEGY:
# 1. Send a file and its clone with -k.
# 2. Clear the clones flag in the BEGIN record and recompute the
#    stream checksums with send_clone_refs_rewrite.py.
# 3. zstream validate passes the original and rejects the copy.
# 4. zfs recv of the copy fails, into a pool with the feature and
#    into one without it, and the original still receives.
#

verify_runnable "global"

function cleanup
{
	destroy_pool pool_nof
	destroy_dataset $POOL/cnf -r
	destroy_dataset $POOL2/cnf -r
	rm -f $BACKDIR/cnf-* $TESTDIR/vdev_nof
}

log_assert "CLONE records without the clones flag are refused"
log_onexit cleanup

typeset src=$POOL/cnf

log_must truncate -s $MINVDEVSIZE $TESTDIR/vdev_nof
log_must zpool create -f -o feature@block_cloning=disabled pool_nof \
    $TESTDIR/vdev_nof

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/f1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f2
log_must sync_pool $POOL
log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/cnf-c"
log_must stream_has_features $BACKDIR/cnf-c clones

#
# Prove the checksum rewrite on this host first: run over a stream
# without the flag, it must change nothing.
#
log_must eval "zfs send $src@s > $BACKDIR/cnf-plain"
log_must stream_rewrite noflag $BACKDIR/cnf-plain $BACKDIR/cnf-plain2
log_must cmp $BACKDIR/cnf-plain $BACKDIR/cnf-plain2

log_must stream_rewrite noflag $BACKDIR/cnf-c $BACKDIR/cnf-noflag
log_mustnot stream_has_features $BACKDIR/cnf-noflag clones

log_must zstream validate $BACKDIR/cnf-c
log_mustnot zstream validate $BACKDIR/cnf-noflag
log_mustnot eval "zfs recv $POOL2/cnf < $BACKDIR/cnf-noflag"
log_mustnot datasetexists $POOL2/cnf
log_mustnot eval "zfs recv pool_nof/cnf < $BACKDIR/cnf-noflag"
log_must zpool status -x pool_nof
log_must eval "zfs recv $POOL2/cnf < $BACKDIR/cnf-c"

log_pass "CLONE records without the clones flag are refused"
