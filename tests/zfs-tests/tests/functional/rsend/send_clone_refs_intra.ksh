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
# A file cloned within one snapshot arrives on the receiver still
# sharing its blocks when sent with -k.
#
# STRATEGY:
# 1. Write a file and clone it with copy_file_range in the same
#    filesystem.
# 2. Snapshot, send with -k to a file, receive into the second pool.
# 3. The stream carries the clones feature and CLONE records.
# 4. Both received files match and share every L0 block.
# 5. zdb -b on the receiving pool is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cr -r
	destroy_dataset $POOL2/cr -r
	rm -f $BACKDIR/cr-full
}

log_assert "zfs send -k preserves sharing inside one snapshot"
log_onexit cleanup

typeset src=$POOL/cr
typeset dst=$POOL2/cr

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=8
log_must sync_pool $POOL
log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
typeset blocks=$(get_same_blocks $src file1 $src file2)
log_must [ "$blocks" = "0 1 2 3 4 5 6 7" ]

log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/cr-full"
log_must stream_has_features $BACKDIR/cr-full clones
log_must [ "$(stream_clone_records $BACKDIR/cr-full)" = "8" ]

log_must eval "zfs recv $dst < $BACKDIR/cr-full"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $dmnt/file1 $dmnt/file2
log_must have_same_content $mnt/file1 $dmnt/file1
blocks=$(get_same_blocks $dst file1 $dst file2)
log_must [ "$blocks" = "0 1 2 3 4 5 6 7" ]
log_must zdb -b $POOL2

log_pass "zfs send -k preserves sharing inside one snapshot"
