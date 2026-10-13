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
# Description:
# When zfs send -R fails partway through one snapshot, it carries on
# with the next, so the stream holds a snapshot with no DRR_END. zfs
# receive must say the stream is incomplete, and must not blame
# encryption on pools that have none.
#
# Strategy:
# 1. Create a filesystem with three snapshots, caching only its
#    metadata so that a send reads its data blocks from disk.
# 2. Inject an EIO on one data block of a file written in the second
#    snapshot, and send the third with "zfs send -Re". The send must
#    report the EIO.
# 3. Receive the stream. The receive must fail, report an incomplete
#    stream and not mention encryption.
#

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

verify_runnable "both"

typeset src=$POOL/incsub
typeset dst=$POOL2/incsub
typeset stream=$BACKDIR/incsub.zsend
typeset err=$BACKDIR/incsub.err

function cleanup
{
	zinject -c all
	datasetexists $src && destroy_dataset $src -r
	datasetexists $dst && destroy_dataset $dst -r
	rm -f $stream $err
}
log_onexit cleanup

log_assert "zfs receive reports a stream whose sender failed midway"

log_must zfs create -o recordsize=128k -o compression=off \
    -o primarycache=metadata $src
typeset mntpnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mntpnt/f1 bs=1024k count=2
log_must zfs snapshot $src@s1
log_must dd if=/dev/urandom of=$mntpnt/f2 bs=1024k count=2
log_must zfs snapshot $src@s2
log_must dd if=/dev/urandom of=$mntpnt/f3 bs=1024k count=2
log_must zfs snapshot $src@s3

typeset objset=$(zfs get -Hp -o value objsetid $src@s2)
typeset object=$(get_objnum $mntpnt/f2)
log_must zinject -b $(printf "%x:%x:0:1:1" $objset $object) -e io $POOL
log_mustnot eval "zfs send -Re $src@s3 > $stream 2> $err"
log_note "send: $(<$err)"
log_must grep -q "$src@s2" $err
log_must zinject -c all

log_mustnot eval "zfs receive -u $dst < $stream > $err 2>&1"
log_note "receive: $(<$err)"
log_must grep -q "incomplete stream" $err
log_mustnot grep -q "encrypt" $err

log_pass "zfs receive reports a stream whose sender failed midway"
