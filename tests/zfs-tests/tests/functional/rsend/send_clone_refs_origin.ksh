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
# A -k incremental from a snapshot into a clone of it references the
# origin's blocks.  The receiver resolves them when the destination is
# created with an origin, by zfs recv -o origin= and inside a -R
# package.
#
# STRATEGY:
# 1. Write a file, snapshot @a, replicate it.
# 2. Clone @a, reflink the file inside the clone, snapshot @b.
# 3. zfs send -k -i @a clone@b, receive with -o origin=; the received
#    copy shares its blocks with the received @a.
# 4. zfs send -R -k -I @a of the tree, receive it; same check for the
#    clone child.
# 5. zdb -b on the receiving pool is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/co -rR
	destroy_dataset $POOL2/co -rR
	destroy_dataset $POOL2/co2 -rR
	rm -f $BACKDIR/co-*
}

log_assert "zfs send -k references the origin of a received clone"
log_onexit cleanup

typeset src=$POOL/co

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=8
log_must zfs snapshot $src@a
log_must eval "zfs send -R $src@a > $BACKDIR/co-full"
log_must eval "zfs recv $POOL2/co < $BACKDIR/co-full"

log_must zfs clone $src@a $src/c
typeset cmnt=$(get_prop mountpoint $src/c)
log_must clonefile -f $cmnt/file1 $cmnt/file2
log_must sync_pool $POOL
log_must [ "$(get_same_blocks $src/c file1 $src/c file2)" = \
    "0 1 2 3 4 5 6 7" ]
log_must zfs snapshot -r $src@b

log_must eval "zfs send -k -i $src@a $src/c@b > $BACKDIR/co-clone"
log_must [ "$(stream_clone_records $BACKDIR/co-clone)" = "8" ]
log_must eval "zfs recv -o origin=$POOL2/co@a $POOL2/co2 \
    < $BACKDIR/co-clone"
typeset dmnt=$(get_prop mountpoint $POOL2/co2)
log_must have_same_content $cmnt/file2 $dmnt/file2
log_must [ "$(get_same_blocks $POOL2/co file1 $POOL2/co2 file2)" = \
    "0 1 2 3 4 5 6 7" ]

log_must eval "zfs send -R -k -I @a $src@b > $BACKDIR/co-repl"
log_must [ "$(stream_clone_records $BACKDIR/co-repl)" -ge 8 ]
log_must eval "zfs recv $POOL2/co < $BACKDIR/co-repl"
dmnt=$(get_prop mountpoint $POOL2/co/c)
log_must have_same_content $cmnt/file2 $dmnt/file2
log_must [ "$(get_same_blocks $POOL2/co file1 $POOL2/co/c file2)" = \
    "0 1 2 3 4 5 6 7" ]
log_must zdb -b $POOL2

log_pass "zfs send -k references the origin of a received clone"
