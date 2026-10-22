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
# Large blocks are sent as CLONE records only with -L, and a receiver
# that holds them at a smaller block size refuses the stream.
#
# STRATEGY:
# 1. Write a file of 1M blocks, snapshot A; receive A with -L into
#    one copy and without -L into another.
# 2. Clone the file, snapshot B.
# 3. zfs send -k of B without -L carries no CLONE records.
# 4. zfs send -L -k -i A B carries one CLONE per block, and the -L
#    copy receives it with every block shared.
# 5. The copy received without -L refuses the same stream, gets no
#    snapshot B, and the error names -L.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/clb -r
	destroy_dataset $POOL2/clb -r
	destroy_dataset $POOL2/clb2 -r
	rm -f $BACKDIR/clb-*
}

log_assert "zfs send -k sends large blocks as CLONEs only with -L"
log_onexit cleanup

typeset src=$POOL/clb
typeset dst=$POOL2/clb
typeset dst2=$POOL2/clb2

log_must zfs create -o recordsize=1M $src
typeset mnt=$(get_prop mountpoint $src)
log_must file_write -o create -f $mnt/file1 -b 1048576 -c 4 -d R
log_must zfs snapshot $src@a
log_must eval "zfs send -L $src@a > $BACKDIR/clb-fullL"
log_must eval "zfs recv $dst < $BACKDIR/clb-fullL"
log_must eval "zfs send $src@a > $BACKDIR/clb-full"
log_must eval "zfs recv $dst2 < $BACKDIR/clb-full"

log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@b

log_must eval "zfs send -k $src@b > $BACKDIR/clb-noL"
log_must [ "$(stream_clone_records $BACKDIR/clb-noL)" = "0" ]

log_must eval "zfs send -L -k -i $src@a $src@b > $BACKDIR/clb-incr"
log_must [ "$(stream_clone_records $BACKDIR/clb-incr)" = "4" ]
log_must eval "zfs recv $dst < $BACKDIR/clb-incr"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $mnt/file2 $dmnt/file2
log_must [ "$(get_same_blocks $dst file1 $dst file2)" = "0 1 2 3" ]

log_mustnot eval "zfs recv $dst2 < $BACKDIR/clb-incr" \
    "> $BACKDIR/clb-err 2>&1"
log_mustnot snapexists $dst2@b
log_must grep -q -- "without -L" $BACKDIR/clb-err

log_pass "zfs send -k sends large blocks as CLONEs only with -L"
