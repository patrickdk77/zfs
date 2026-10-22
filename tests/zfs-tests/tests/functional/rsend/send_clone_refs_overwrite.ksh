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
# A CLONE record that references a block the same incremental stream
# overwrote clones the new block, not the one it replaced.
#
# STRATEGY:
# 1. Fill file1 and file2 with one repeated byte, snapshot A, send A
#    and receive it.
# 2. Overwrite all of file1 with random data, so a stale block cannot
#    match it, clone it over file2, snapshot B.  Both
#    files then hold new blocks, so whichever gets the lower object
#    number carries the WRITEs and the other's CLONEs refer to
#    blocks that the stream overwrote.
# 3. Send -k -i A B; the stream carries 8 CLONE records.
# 4. Receive; both files match the source and file2 shares every
#    block with file1 on the receiver.
# 5. zdb -b on the receiving pool is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cw -r
	destroy_dataset $POOL2/cw -r
	rm -f $BACKDIR/cw-full $BACKDIR/cw-incr
}

log_assert "a CLONE refers to the new copy of an overwritten block"
log_onexit cleanup

typeset src=$POOL/cw
typeset dst=$POOL2/cw

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must file_write -o create -f $mnt/file1 -b 131072 -c 8 -d 66
log_must file_write -o create -f $mnt/file2 -b 131072 -c 8 -d 66
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a > $BACKDIR/cw-full"
log_must eval "zfs recv $dst < $BACKDIR/cw-full"

log_must file_write -o overwrite -f $mnt/file1 -b 131072 -c 8 -d R
log_must sync_pool $POOL
log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@b
log_must eval "zfs send -k -i $src@a $src@b > $BACKDIR/cw-incr"
log_must [ "$(stream_clone_records $BACKDIR/cw-incr)" = "8" ]

log_must eval "zfs recv $dst < $BACKDIR/cw-incr"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $mnt/file1 $dmnt/file1
log_must have_same_content $mnt/file2 $dmnt/file2
typeset blocks=$(get_same_blocks $dst file1 $dst file2)
log_must [ "$blocks" = "0 1 2 3 4 5 6 7" ]
log_must zdb -b $POOL2

log_pass "a CLONE refers to the new copy of an overwritten block"
