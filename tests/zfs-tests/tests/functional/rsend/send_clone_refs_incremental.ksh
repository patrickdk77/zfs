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
# Blocks cloned after the from-snapshot arrive shared after an
# incremental send with -k, by reference into the from-snapshot.
#
# STRATEGY:
# 1. Write file1, snapshot A, send A with -k and receive it.
# 2. Clone file1 to file2, snapshot B.
# 3. Send -k -i A B; the stream carries CLONE records.
# 4. Receive; file2 shares every block with file1 on the receiver.
# 5. zdb -b on the receiving pool is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/ci -r
	destroy_dataset $POOL2/ci -r
	rm -f $BACKDIR/ci-full $BACKDIR/ci-incr
}

log_assert "zfs send -k -i references blocks in the from-snapshot"
log_onexit cleanup

typeset src=$POOL/ci
typeset dst=$POOL2/ci

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=8
log_must zfs snapshot $src@a
log_must eval "zfs send -k $src@a > $BACKDIR/ci-full"
log_must eval "zfs recv $dst < $BACKDIR/ci-full"

log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@b
log_must eval "zfs send -k -i $src@a $src@b > $BACKDIR/ci-incr"
log_must stream_has_features $BACKDIR/ci-incr clones
log_must [ "$(stream_clone_records $BACKDIR/ci-incr)" = "8" ]

log_must eval "zfs recv $dst < $BACKDIR/ci-incr"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $dmnt/file1 $dmnt/file2
typeset blocks=$(get_same_blocks $dst file1 $dst file2)
log_must [ "$blocks" = "0 1 2 3 4 5 6 7" ]
log_must zdb -b $POOL2

log_pass "zfs send -k -i references blocks in the from-snapshot"
