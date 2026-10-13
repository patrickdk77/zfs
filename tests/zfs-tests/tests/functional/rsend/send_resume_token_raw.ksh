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
# zfs send -w -t sends a raw stream even when the resume token came
# from a send that was not raw.
#
# Strategy:
# 1. Cut a plain send of an encrypted dataset short and save the
#    resume token of the receive.
# 2. Resume with zfs send -t. The stream must not be raw.
# 3. Resume with zfs send -w -t. The stream must be raw.
#

verify_runnable "both"

typeset passphrase="password1"
typeset src=$POOL/rrt_src
typeset dst=$POOL2/rrt_dst
typeset stream=$BACKDIR/rrt.zs

function cleanup
{
	for ds in $src $dst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	rm -f $BACKDIR/rrt.*
}

function object_ranges # stream
{
	zstream dump $1 | \
	    awk '/Total DRR_OBJECT_RANGE records/ {print $5}'
}

log_assert "zfs send -w -t sends a raw stream"
log_onexit cleanup

log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $src"
log_must dd if=/dev/urandom of=/$src/f1 bs=128k count=64 status=none
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a >$stream"
typeset -i half=$(stat_size $stream)/2
log_mustnot eval "head -c $half $stream | zfs recv -s -u $dst"
typeset tok=$(get_prop receive_resume_token $dst)
log_must test "$tok" != "-"

log_must eval "zfs send -t $tok >$BACKDIR/rrt.plain"
typeset -i n=$(object_ranges $BACKDIR/rrt.plain)
log_note "OBJECT_RANGE records without -w: $n"
log_must test $n -eq 0

log_must eval "zfs send -w -t $tok >$BACKDIR/rrt.raw"
n=$(object_ranges $BACKDIR/rrt.raw)
log_note "OBJECT_RANGE records with -w: $n"
log_must test $n -gt 0

log_pass "zfs send -w -t sends a raw stream"
