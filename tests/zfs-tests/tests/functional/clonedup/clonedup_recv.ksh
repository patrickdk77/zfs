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
#
# Copyright (c) 2026, Patrick Domack. All rights reserved.
#

. $STF_SUITE/tests/functional/clonedup/clonedup.kshlib

#
# DESCRIPTION:
#	Before it takes its snapshot, zfs receive -K clones the
#	received blocks onto identical blocks that a snapshot on the
#	pool holds, and -k clones them onto each other without
#	looking at the pool.  Without either the receive stores a
#	second copy.  An incremental with -K clones the blocks it
#	brings, and the next incremental still applies because the
#	head was never modified after its snapshot.
#

verify_runnable "global"

log_assert \
    "zfs receive -k and -K clone received blocks before the snapshot"
log_onexit clonedup_cleanup
typeset all="$(clonedup_all_blocks)"

clonedup_pool_create
log_must zfs create $TESTPOOL/src
clonedup_write /$TESTPOOL/src/f
clonedup_dup /$TESTPOOL/src/f /$TESTPOOL/src/f2
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1

# get_same_blocks reads through zdb, so every check below needs the
# clones on disk, not merely committed.  dsl_clonedup_recv() waits
# for a synced txg before it starts and not after it finishes, so
# when the ioctl returns its clones are in an open txg.
#
# a plain receive stores every copy again
log_must eval "zfs send $TESTPOOL/src@1 | zfs recv $TESTPOOL/plain"
clonedup_sync
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/plain f ""
clonedup_check_shared $TESTPOOL/plain f $TESTPOOL/plain f2 ""
clonedup_kstat_is recv_runs 0

# -k: the stream's duplicates share each other, and the pool is not
# consulted.  The clones go out in batches, not a transaction each.
typeset -i batches=$(clonedup_kstat batches)
typeset -i clones=$(clonedup_kstat clones)
log_must eval "zfs send $TESTPOOL/src@1 | zfs recv -k $TESTPOOL/quick"
clonedup_sync
clonedup_check_shared $TESTPOOL/quick f $TESTPOOL/quick f2 "$all"
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/quick f ""
clonedup_kstat_is recv_runs 1
clonedup_kstat_is match_walks 0
((batches = $(clonedup_kstat batches) - batches))
((clones = $(clonedup_kstat clones) - clones))
log_note "-k cloned $clones blocks in $batches transactions"
log_must [ $clones -eq $CD_BLOCKS ]
log_must [ $batches -lt $clones ]
log_must cmp /$TESTPOOL/src/f /$TESTPOOL/quick/f
log_must cmp /$TESTPOOL/src/f2 /$TESTPOOL/quick/f2

# -K: the received copies land on a copy that was already there.
# Which one is not asserted.  Six copies of this content are in the
# pool by now, f and f2 in each of src, plain and quick, and each
# dataset's @1 holds its two.  The preference between them reads
# DCE_F_MAYBE_SHARED, which the index walk stores from
# brt_maybe_exists(), an approximate range check.  What -K
# guarantees for a block that a snapshot holds is that it is not
# stored again, so every block lands on one of the six.
typeset -i bsaved=$(zpool get -Hpo value bclonesaved $TESTPOOL)
log_must eval "zfs send $TESTPOOL/src@1 | zfs recv -K $TESTPOOL/rcv"
# a read through the mount would write atime to the head
log_must zfs set atime=off $TESTPOOL/rcv
clonedup_sync
# Log which of the six copies each block landed on.  The assertion
# below reports only that some block landed on none of them.
typeset on_f on_f2
for cds in src plain quick; do
	on_f=$(clonedup_shared $TESTPOOL/$cds f $TESTPOOL/rcv f)
	on_f2=$(clonedup_shared $TESTPOOL/$cds f2 $TESTPOOL/rcv f)
	log_note "rcv f landed on: $cds" "f '$on_f'" "f2 '$on_f2'"
done
clonedup_check_shared_any $TESTPOOL/rcv f "$all" \
    $TESTPOOL/quick f $TESTPOOL/quick f2 \
    $TESTPOOL/src f $TESTPOOL/src f2 \
    $TESTPOOL/plain f $TESTPOOL/plain f2
clonedup_check_shared_any $TESTPOOL/rcv f2 "$all" \
    $TESTPOOL/quick f $TESTPOOL/quick f2 \
    $TESTPOOL/src f $TESTPOOL/src f2 \
    $TESTPOOL/plain f $TESTPOOL/plain f2
clonedup_kstat_is recv_runs 2
clonedup_kstat_is match_walks 1
log_must [ $(zpool get -Hpo value bclonesaved $TESTPOOL) -gt $bsaved ]
log_must cmp /$TESTPOOL/src/f /$TESTPOOL/rcv/f
log_must cmp /$TESTPOOL/src/f2 /$TESTPOOL/rcv/f2

# an incremental with -K clones the blocks it brings onto the
# copies that src@2 holds
clonedup_write /$TESTPOOL/src/g
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@2
log_must eval \
    "zfs send -i @1 $TESTPOOL/src@2 | zfs recv -K $TESTPOOL/rcv"
clonedup_sync
clonedup_check_shared $TESTPOOL/src g $TESTPOOL/rcv g "$all"
clonedup_kstat_is recv_runs 3
log_must cmp /$TESTPOOL/src/g /$TESTPOOL/rcv/g

# the next incremental applies without -F: the head was not modified
clonedup_write /$TESTPOOL/src/h
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@3
log_must eval \
    "zfs send -i @2 $TESTPOOL/src@3 | zfs recv $TESTPOOL/rcv"
clonedup_sync
log_must [ -f /$TESTPOOL/rcv/h ]
log_must cmp /$TESTPOOL/src/f /$TESTPOOL/rcv/.zfs/snapshot/1/f
log_must cmp /$TESTPOOL/src/g /$TESTPOOL/rcv/.zfs/snapshot/2/g
log_must cmp /$TESTPOOL/src/h /$TESTPOOL/rcv/.zfs/snapshot/3/h

clonedup_leakcheck

log_pass \
    "zfs receive -k and -K clone received blocks before the snapshot"
