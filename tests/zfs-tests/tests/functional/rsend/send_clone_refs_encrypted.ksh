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
# A non-raw incremental send with -k of an encrypted dataset
# references blocks in the from-snapshot.
#
# STRATEGY:
# 1. Create an encrypted filesystem, write file1, snapshot A, send A
#    without -w and receive it.
# 2. Clone file1 to file2, snapshot B.
# 3. Export and import the pool so A's dnode blocks are not cached
#    decrypted, and load the key.
# 4. zfs send -k -i A B without -w succeeds and carries 8 CLONE
#    records.
# 5. Receive; contents match and file2 shares every block with file1
#    on the receiver.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cn -r
	destroy_dataset $POOL2/cn -r
	rm -f $BACKDIR/cn-full $BACKDIR/cn-incr
}

log_assert "encrypted -k incrementals reference the from-snapshot"
log_onexit cleanup

typeset src=$POOL/cn
typeset dst=$POOL2/cn
typeset passphrase="password"

log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase -o recordsize=128k $src"
typeset mnt=$(get_prop mountpoint $src)
log_must file_write -o create -f $mnt/file1 -b 131072 -c 8 -d R
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a > $BACKDIR/cn-full"
log_must eval "zfs recv $dst < $BACKDIR/cn-full"

log_must clonefile -f $mnt/file1 $mnt/file2
log_must sync_pool $POOL
log_must zfs snapshot $src@b

log_must_busy zpool export $POOL
log_must zpool import $POOL
log_must eval "echo $passphrase | zfs load-key $src"
log_must zfs mount $src

log_must eval "zfs send -k -i $src@a $src@b > $BACKDIR/cn-incr"
log_must stream_has_features $BACKDIR/cn-incr clones
log_must [ "$(stream_clone_records $BACKDIR/cn-incr)" = "8" ]

log_must eval "zfs recv $dst < $BACKDIR/cn-incr"
typeset dmnt=$(get_prop mountpoint $dst)
log_must have_same_content $mnt/file1 $dmnt/file1
log_must have_same_content $mnt/file2 $dmnt/file2
typeset blocks=$(get_same_blocks $dst file1 $dst file2)
log_must [ "$blocks" = "0 1 2 3 4 5 6 7" ]

log_pass "encrypted -k incrementals reference the from-snapshot"
