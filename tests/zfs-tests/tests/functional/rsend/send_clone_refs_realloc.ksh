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
# An incremental that reallocates objects at a new dnode size makes
# the receiver defer their writes.  A clone of one of those blocks
# must wait for the write, or it clones a hole.
#
# STRATEGY:
# 1. Write files with 1k dnodes, snapshot, send and receive.
# 2. Recreate the files with legacy dnodes, reusing the object
#    numbers, and clone ten of them into new files.
# 3. Send -k -i and receive.
# 4. Every received file matches its source; zdb -b is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/crl -rR
	destroy_dataset $POOL2/crl -rR
	rm -f $BACKDIR/crl-full $BACKDIR/crl-incr
}

log_assert "a clone of a deferred write receives its data"
log_onexit cleanup

typeset src=$POOL/crl
typeset dst=$POOL2/crl

log_must zfs create -o dnodesize=1k $src
typeset mnt=$(get_prop mountpoint $src)
log_must mk_files 100 262144 0 $src
log_must zfs snapshot $src@a
log_must eval "zfs send $src@a > $BACKDIR/crl-full"
log_must eval "zfs recv $dst < $BACKDIR/crl-full"

log_must rm $mnt/*
log_must zfs unmount $src
log_must zfs set dnodesize=legacy $src
log_must zfs mount $src
log_must mk_files 100 262144 0 $src
log_must sync_pool $POOL
for f in $(ls $mnt | head -10); do
	log_must clonefile -f $mnt/$f $mnt/$f.c
done
log_must sync_pool $POOL
log_must zfs snapshot $src@b

log_must eval "zfs send -k -i $src@a $src@b > $BACKDIR/crl-incr"
typeset n=$(stream_clone_records $BACKDIR/crl-incr)
log_must [ "$n" -gt 0 ]
log_must eval "zfs recv $dst < $BACKDIR/crl-incr"

typeset dmnt=$(get_prop mountpoint $dst)
for f in $(ls $mnt); do
	log_must have_same_content $mnt/$f $dmnt/$f
done
log_must zdb -b $POOL2

log_pass "a clone of a deferred write receives its data"
