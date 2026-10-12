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
# A raw incremental receive must accept a destination that has empty
# snapshots after the stream's from snapshot, as a non-raw receive
# does, and must still refuse one whose newer snapshots hold changes.
#
# Strategy:
# 1. Receive a raw full stream, take two snapshots on the destination
#    and receive a raw incremental without -F. The data and the
#    sender's ivset guid must arrive and the local snapshots stay.
# 2. Take another empty snapshot, cut a raw incremental short and
#    resume it with zfs send -t.
# 3. Write to the destination, snapshot it, and check that a raw
#    incremental is refused.
#

verify_runnable "both"

typeset passphrase="password1"
typeset src=$POOL/rds_src
typeset dst=$POOL2/rds_dst
typeset stream=$BACKDIR/rds.zs

function cleanup
{
	for ds in $src $dst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	rm -f $BACKDIR/rds.*
}

function add_file # name
{
	log_must dd if=/dev/urandom of=/$src/$1 bs=128k count=8 \
	    status=none
}

log_assert "A raw incremental is received over empty destination" \
    "snapshots"
log_onexit cleanup

log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $src"
add_file f1
log_must zfs snapshot $src@a
log_must eval "zfs send -w $src@a | zfs recv -u $dst"

log_must zfs snapshot $dst@local1
log_must zfs snapshot $dst@local2
add_file f2
log_must zfs snapshot $src@b
log_must eval "zfs send -w -i @a $src@b | zfs recv -u $dst"
log_must snapexists $dst@local1
log_must snapexists $dst@local2
log_must test "$(get_prop ivsetguid $dst@b)" = \
    "$(get_prop ivsetguid $src@b)"
log_must eval "echo $passphrase | zfs load-key $dst"
log_must zfs mount $dst
log_must cmp /$src/f2 /$dst/f2
log_must zfs unmount $dst
log_must zfs rollback $dst@b

log_must zfs snapshot $dst@local3
add_file f3
log_must zfs snapshot $src@c
log_must eval "zfs send -w -i @b $src@c >$stream"
typeset -i half=$(stat_size $stream)/2
log_mustnot eval "head -c $half $stream | zfs recv -s -u $dst"
typeset tok=$(get_prop receive_resume_token $dst)
log_must test "$tok" != "-"
log_must eval "zfs send -t $tok | zfs recv -s -u $dst"
log_must zfs mount $dst
log_must cmp /$src/f3 /$dst/f3

log_must eval "echo local >/$dst/f4"
log_must zfs snapshot $dst@dirty
log_must zfs unmount $dst
log_must zfs rollback $dst@dirty
add_file f5
log_must zfs snapshot $src@d
log_mustnot eval "zfs send -w -i @c $src@d | zfs recv -u $dst"

log_pass "A raw incremental is received over empty destination" \
    "snapshots"
