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

#
# Description:
# A snapshot taken while a file is unlinked but still open carries
# that file in the unlinked set. Mounting a received copy of it, and
# receiving an incremental into it while mounted, must not write to
# the copy, and zfs wait -t deleteq must return. The first unlink on
# the copy then drains the set. A clone of the snapshot, and a mount
# that has to replay the ZIL, drain the set at mount.
#
# Strategy:
# 1. Hold a file open, unlink it, snapshot, and receive the snapshot
#    with a mount. zfs wait -t deleteq must return within 30
#    seconds, and written must then be 0.
# 2. Receive an incremental into the mounted copy without -F and
#    make the same two checks.
# 3. Remove a received file from the copy. The dataset kstat must
#    show it and the held file freed, and zfs wait -t deleteq must
#    return.
# 4. Clone the first received snapshot. The kstat of the clone must
#    show the held file freed.
# 5. On a pool of its own, write synchronously so a dataset has a
#    ZIL, then hold a file open, unlink it and snapshot. Freeze the
#    pool and check that written is 0. Write a new file
#    synchronously, close the held file, unmount, export and import.
#    The mount must drain the unlinked file and replay the new one.
#

verify_runnable "global"

typeset src=$POOL/ud_src
typeset dst=$POOL2/ud_dst
typeset clone=$POOL2/ud_clone
typeset frz=pool_ud
typeset vdev=$TESTDIR/ud_vdev

function cleanup
{
	exec 7<&- 8<&-
	datasetexists $clone && destroy_dataset $clone
	for ds in $src $dst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	poolexists $frz && destroy_pool $frz
	rm -f $vdev
}

function check_written_zero # dataset
{
	sync_pool ${1%%/*}
	log_note "$1 written: $(get_prop written $1)"
	log_must test "$(get_prop written $1)" = "0"
}

function check_unwritten # dataset
{
	log_must timeout 30 zfs wait -t deleteq $1
	check_written_zero $1
}

function check_drained # dataset count
{
	typeset -i n=0 drained=0

	while ((n < 30)); do
		drained=$(kstat_dataset $1 nunlinked)
		((drained >= $2)) && break
		sleep 1
		((n++))
	done
	log_note "$1 nunlinked: $drained"
	log_must test $drained -ge $2
}

log_assert "Mounting a received dataset does not drain its" \
    "unlinked set before the first unlink"
log_onexit cleanup

log_must zfs create $src
typeset srcmnt=$(get_prop mountpoint $src)
log_must test -n "$srcmnt"
log_must file_write -o create -f $srcmnt/held -b 1048576 -c 4 -d R
exec 7<$srcmnt/held
log_must rm $srcmnt/held
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a | zfs recv $dst"
typeset dstmnt=$(get_prop mountpoint $dst)
log_must test -n "$dstmnt"
log_must ismounted $dst
check_unwritten $dst

log_must eval "echo two >$srcmnt/f2"
log_must zfs snapshot $src@b
log_must eval "zfs send -i @a $src@b | zfs recv $dst"
check_unwritten $dst
log_must cmp $srcmnt/f2 $dstmnt/f2

log_must rm $dstmnt/f2
check_drained $dst 2
log_must timeout 60 zfs wait -t deleteq $dst

log_must zfs clone $dst@a $clone
log_must ismounted $clone
check_drained $clone 1

log_must truncate -s $MINVDEVSIZE $vdev
log_must zpool create -f $frz $vdev
log_must zfs create $frz/fs
typeset fmnt=$(get_prop mountpoint $frz/fs)
log_must test -n "$fmnt"
log_must file_write -o create -w -f $fmnt/sync -b 512 -c 1 -d R
log_must file_write -o create -f $fmnt/held -b 131072 -c 1 -d R
exec 8<$fmnt/held
log_must rm $fmnt/held
log_must zfs snapshot $frz/fs@a
log_must zpool freeze $frz
check_written_zero $frz/fs
log_must file_write -o create -w -f $fmnt/new -b 4096 -c 1 -d R
typeset sum=$(xxh128digest $fmnt/new)
log_must test -n "$sum"
exec 8<&-
log_must zfs unmount $frz/fs
log_must zpool export $frz
log_must zpool import -f -d $TESTDIR $frz
check_drained $frz/fs 1
log_must test "$(xxh128digest $fmnt/new)" = "$sum"

log_pass "Mounting a received dataset does not drain its" \
    "unlinked set before the first unlink"
