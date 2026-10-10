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
# A raw send of an encrypted dataset never emits CLONE records, even
# when -k is given and the dataset has shared blocks.
#
# STRATEGY:
# 1. Create an encrypted filesystem, write a file and clone it.
# 2. zfs send -w -k: the stream has no clones feature and zero
#    CLONE records, and receives correctly.
# 3. zfs send -k without -w on the same snapshot does emit them.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/ce -r
	destroy_dataset $POOL2/ce -r
	destroy_dataset $POOL2/ce2 -r
	rm -f $BACKDIR/ce-raw $BACKDIR/ce-plain
}

log_assert "raw sends carry no CLONE records"
log_onexit cleanup

typeset src=$POOL/ce
typeset passphrase="password"

log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase -o recordsize=128k $src"
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@s

log_must eval "zfs send -w -k $src@s > $BACKDIR/ce-raw"
log_mustnot stream_has_features $BACKDIR/ce-raw clones
log_must [ "$(stream_clone_records $BACKDIR/ce-raw)" = "0" ]
log_must eval "zfs recv $POOL2/ce < $BACKDIR/ce-raw"

log_must eval "zfs send -k $src@s > $BACKDIR/ce-plain"
log_must stream_has_features $BACKDIR/ce-plain clones
log_must [ "$(stream_clone_records $BACKDIR/ce-plain)" = "4" ]
log_must eval "zfs recv $POOL2/ce2 < $BACKDIR/ce-plain"
typeset dmnt=$(get_prop mountpoint $POOL2/ce2)
log_must have_same_content $dmnt/file1 $dmnt/file2

log_pass "raw sends carry no CLONE records"
