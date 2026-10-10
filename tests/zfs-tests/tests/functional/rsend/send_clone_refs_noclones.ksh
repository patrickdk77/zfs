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
# zfs send -k on a snapshot with nothing shared emits no CLONE records
# and receives like an ordinary stream.
#
# STRATEGY:
# 1. Write two unrelated files, snapshot.
# 2. Send with -k; the stream has zero CLONE records.
# 3. Receive and compare contents.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cn -r
	destroy_dataset $POOL2/cn -r
	rm -f $BACKDIR/cn-full
}

log_assert "zfs send -k without shared blocks emits no CLONE records"
log_onexit cleanup

typeset src=$POOL/cn
typeset dst=$POOL2/cn

log_must zfs create $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=4
log_must dd if=/dev/urandom of=$mnt/file2 bs=128k count=4
log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/cn-full"
log_must [ "$(stream_clone_records $BACKDIR/cn-full)" = "0" ]

log_must eval "zfs recv $dst < $BACKDIR/cn-full"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $mnt/file1 $dmnt/file1
log_must have_same_content $mnt/file2 $dmnt/file2

log_pass "zfs send -k without shared blocks emits no CLONE records"
