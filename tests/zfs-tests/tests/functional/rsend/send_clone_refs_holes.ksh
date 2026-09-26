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
# A receiver that compresses can store the first copy of a cloned
# block as a hole or an embedded block.  The clone of it must still
# receive, and read back the same data.
#
# STRATEGY:
# 1. With compression off, write two zero blocks, two blocks that
#    compress to almost nothing, and two random blocks, then clone
#    the file.
# 2. Send with -k and receive with -o compression=lz4.
# 3. Both received files match the source; zdb -b is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/chl -r
	destroy_dataset $POOL2/chl -r
	rm -f $BACKDIR/chl-full
}

log_assert "a clone of a block received as a hole or embedded works"
log_onexit cleanup

typeset src=$POOL/chl
typeset dst=$POOL2/chl

log_must zfs create -o recordsize=128k -o compression=off $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/zero of=$mnt/f1 bs=128k count=2
log_must eval "yes | head -c 262144 >> $mnt/f1"
log_must eval "dd if=/dev/urandom bs=128k count=2 >> $mnt/f1"
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f2
log_must sync_pool $POOL
log_must [ "$(get_same_blocks $src f1 $src f2)" = "0 1 2 3 4 5" ]

log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/chl-full"
log_must [ "$(stream_clone_records $BACKDIR/chl-full)" = "6" ]

log_must eval "zfs recv -o compression=lz4 $dst < $BACKDIR/chl-full"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $mnt/f1 $dmnt/f1
log_must have_same_content $mnt/f1 $dmnt/f2
log_must zdb -b $POOL2

log_pass "a clone of a block received as a hole or embedded works"
