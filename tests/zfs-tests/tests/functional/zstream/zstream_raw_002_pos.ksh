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

. $STF_SUITE/tests/functional/zstream/zstream.kshlib
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
# zstream raw rebuilds a volume from a zfs send -k stream.  Once a
# pool holds cloned blocks, every -k stream from it carries the
# clones feature, so zstream raw has to accept the flag.
#
# STRATEGY:
# 1. Clone a file in the pool so that block cloning is active.
# 2. Fill a volume, snapshot it and send it with -k; the stream has
#    the clones feature.
# 3. zstream raw rebuilds the volume; the image matches the snapshot.
#

verify_runnable "global"

typeset volume=$POOL/zrk
typeset fs=$POOL/zrkfs
typeset stream=$BACKDIR/zrk.zsend
typeset image=$BACKDIR/zrk.img

function cleanup
{
	destroy_dataset $volume -r
	destroy_dataset $fs -r
	rm -f $stream $image
}

log_assert "zstream raw accepts a volume sent with -k"
log_onexit cleanup

log_must zfs create -o recordsize=128k $fs
typeset mnt=$(get_prop mountpoint $fs)
log_must dd if=/dev/urandom of=$mnt/f1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f2
log_must sync_pool $POOL
log_must [ "$(get_same_blocks $fs f1 $fs f2)" = "0 1 2 3" ]

log_must zfs create -V 16m -o snapdev=visible $volume
block_device_wait $ZVOL_DEVDIR/$volume
log_must dd if=/dev/urandom of=$ZVOL_DEVDIR/$volume bs=1048576 \
    count=16
log_must sync_pool $POOL
log_must zfs snapshot $volume@s
block_device_wait $ZVOL_DEVDIR/$volume@s

log_must eval "zfs send -k $volume@s > $stream"
log_must stream_has_features $stream clones
log_must eval "zstream raw $image < $stream > /dev/null"
log_must cmp $ZVOL_DEVDIR/$volume@s $image

log_pass "zstream raw accepts a volume sent with -k"
