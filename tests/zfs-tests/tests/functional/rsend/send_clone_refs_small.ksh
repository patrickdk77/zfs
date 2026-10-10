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
# Single-block files have block sizes that are not powers of two.
# Cloned copies of them arrive shared after zfs send -k.
#
# STRATEGY:
# 1. Write two small files, one block each, and clone both.
# 2. Send with -k; the stream carries two CLONE records.
# 3. Receive; each pair matches and shares its block.
# 4. zdb -b on the receiving pool is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/csm -r
	destroy_dataset $POOL2/csm -r
	rm -f $BACKDIR/csm-full
}

log_assert "zfs send -k keeps odd-sized single-block files shared"
log_onexit cleanup

typeset src=$POOL/csm
typeset dst=$POOL2/csm

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/f1 bs=3000 count=1
log_must dd if=/dev/urandom of=$mnt/f2 bs=70000 count=1
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f1c
log_must clonefile -f $mnt/f2 $mnt/f2c
log_must sync_pool $POOL
log_must [ "$(get_same_blocks $src f1 $src f1c)" = "0" ]
log_must [ "$(get_same_blocks $src f2 $src f2c)" = "0" ]

log_must zfs snapshot $src@s
log_must eval "zfs send -k $src@s > $BACKDIR/csm-full"
log_must stream_has_features $BACKDIR/csm-full clones
log_must [ "$(stream_clone_records $BACKDIR/csm-full)" = "2" ]

log_must eval "zfs recv $dst < $BACKDIR/csm-full"
typeset dmnt=$(get_prop mountpoint $dst)
for f in f1 f2; do
	log_must have_same_content $mnt/$f $dmnt/$f
	log_must have_same_content $dmnt/$f $dmnt/${f}c
	log_must [ "$(get_same_blocks $dst $f $dst ${f}c)" = "0" ]
done
log_must zdb -b $POOL2

log_pass "zfs send -k keeps odd-sized single-block files shared"
