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
# A DRR_CLONE that references its own destination, or any block at or
# after it in the stream, is refused.  A sender never emits one, and
# installing it would leave a dangling BRT reference.
#
# STRATEGY:
# 1. Send a file and its clone with -k.
# 2. Rewrite the first CLONE record to reference itself and recompute
#    the checksums.
# 3. zfs recv of the copy fails and leaves no dataset; the original
#    still receives, and zdb -b is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/csr -r
	destroy_dataset $POOL2/csr -r
	rm -f $BACKDIR/csr-*
}

log_assert "a self-referencing CLONE record is refused"
log_onexit cleanup

typeset src=$POOL/csr

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/f1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f2
log_must sync_pool $POOL
log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/csr-c"
log_must [ "$(stream_clone_records $BACKDIR/csr-c)" = "4" ]

log_must stream_rewrite selfref $BACKDIR/csr-c $BACKDIR/csr-self
log_mustnot cmp $BACKDIR/csr-c $BACKDIR/csr-self
log_must zstream dump $BACKDIR/csr-self

log_mustnot eval "zfs recv $POOL2/csr < $BACKDIR/csr-self"
log_mustnot datasetexists $POOL2/csr
log_must eval "zfs recv $POOL2/csr < $BACKDIR/csr-c"
typeset dmnt=$(get_prop mountpoint $POOL2/csr)
log_must have_same_content $dmnt/f1 $dmnt/f2
log_must zdb -b $POOL2

log_pass "a self-referencing CLONE record is refused"
