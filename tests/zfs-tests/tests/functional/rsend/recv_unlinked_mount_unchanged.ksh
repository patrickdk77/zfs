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
# receiving an incremental into it while mounted, must not drain the
# set: the dataset would no longer match its snapshot and the next
# incremental would need -F. Once the copy has been written to, a
# remount drains the set as before.
#
# Strategy:
# 1. Hold a file open, unlink it, snapshot, and receive the snapshot
#    with a mount. written must be 0.
# 2. Receive an incremental into the mounted copy without -F.
#    written must be 0.
# 3. Write to the copy and remount it. On Linux, the objset kstat
#    must show the unlinked file drained.
#

verify_runnable "both"

typeset src=$POOL/ud_src
typeset dst=$POOL2/ud_dst

function cleanup
{
	exec 7<&-
	for ds in $src $dst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
}

function check_unwritten # dataset
{
	sync_pool $POOL2
	sleep 1
	sync_pool $POOL2
	log_note "$1 written: $(get_prop written $1)"
	log_must test "$(get_prop written $1)" = "0"
}

log_assert "Mounting a received dataset does not drain its" \
    "unlinked set"
log_onexit cleanup

log_must zfs create $src
log_must dd if=/dev/urandom of=/$src/held bs=1024k count=4 status=none
exec 7</$src/held
log_must rm /$src/held
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a | zfs recv $dst"
log_must ismounted $dst
check_unwritten $dst

log_must eval "echo two >/$src/f2"
log_must zfs snapshot $src@b
log_must eval "zfs send -i @a $src@b | zfs recv $dst"
check_unwritten $dst
log_must cmp /$src/f2 /$dst/f2

if is_linux; then
	log_must eval "echo local >/$dst/f3"
	log_must zfs unmount $dst
	log_must zfs mount $dst
	typeset id=$(printf "0x%x" $(get_prop objsetid $dst))
	typeset ks=/proc/spl/kstat/zfs/$POOL2/objset-$id
	typeset -i n=0 drained=0
	while ((n < 30)); do
		drained=$(awk '$1 == "nunlinked" {print $3}' $ks)
		((drained > 0)) && break
		sleep 1
		((n++))
	done
	log_note "nunlinked after the remount: $drained"
	log_must test $drained -gt 0
fi

log_pass "Mounting a received dataset does not drain its" \
    "unlinked set"
