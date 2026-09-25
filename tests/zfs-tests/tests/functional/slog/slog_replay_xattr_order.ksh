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
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#

. $STF_SUITE/tests/functional/slog/slog.kshlib

#
# DESCRIPTION:
#	An fsync that commits a link, unlink or rename also commits
#	the xattr=sa removal logged before it, and replay keeps the
#	removal.
#
# STRATEGY:
#	1. Create a pool with xattr=sa and a ZIL header
#	2. Freeze the pool
#	3. Remove an xattr from each of three files, then link one,
#	   unlink a second link of another and rename the third
#	4. Commit the log by fsyncing an unrelated file, and check
#	   that the log already holds all three TX_SETSAXATTR records
#	5. Turn every write to the log devices into a no-op, so that
#	   unmounting cannot commit anything more, as after a crash
#	6. Replay the log and check that each namespace change is
#	   present and each removed xattr is still gone
#

verify_runnable "global"

log_assert "Replay keeps an xattr removal ordered before a link"
function cleanup_order
{
	zinject -c all
	cleanup
}

log_onexit cleanup_order
log_must setup

log_must zpool create $TESTPOOL $VDEV log mirror $LDEV
log_must zfs create -o xattr=sa $TESTPOOL/$TESTFS
typeset fs=/$TESTPOOL/$TESTFS

for f in link unlink rename; do
	log_must touch $fs/$f
	log_must set_xattr keep keepvalue $fs/$f
	log_must set_xattr drop dropvalue $fs/$f
done
log_must ln $fs/unlink $fs/unlink.2
log_must touch $fs/other

log_must dd if=/dev/zero of=$fs/sync conv=fdatasync,fsync bs=1 count=1
log_must zpool freeze $TESTPOOL

for f in link unlink rename; do
	log_must rm_xattr drop $fs/$f
done
log_must ln $fs/link $fs/link.2
log_must rm $fs/unlink.2
log_must mv $fs/rename $fs/rename.2
log_must dd if=/dev/zero of=$fs/other conv=notrunc,fsync bs=1 \
    count=1

log_must zdb -iv $TESTPOOL/$TESTFS
typeset -i n=$(zdb -iv $TESTPOOL/$TESTFS | \
    grep -c 'TX_SETSAXATTR .* seq ')
(( n == 3 )) || log_fail "$n of 3 TX_SETSAXATTR records in the log"

for d in $LDEV; do
	log_must zinject -d $d -e noop -T write $TESTPOOL
done
log_must zfs unmount $fs
log_must zinject -c all
log_must zpool export $TESTPOOL
log_must zpool import -f -d $VDIR $TESTPOOL

log_must test -f $fs/link.2
log_must test ! -e $fs/unlink.2
log_must test -f $fs/rename.2
for f in link.2 unlink rename.2; do
	log_must get_xattr keep $fs/$f
	log_mustnot get_xattr drop $fs/$f
done

log_pass "Replay keeps an xattr removal ordered before a link"
