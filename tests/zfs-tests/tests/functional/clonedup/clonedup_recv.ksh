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
#	zfs receive -K clones the received blocks onto identical
#	blocks already on the pool before the snapshot is taken, and
#	-k clones them onto each other without looking at the pool.
#	Without either the receive stores a second copy.  An
#	incremental with -K clones the blocks it brings, and the next
#	incremental still applies because the head was never modified
#	after its snapshot.
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
# consulted
log_must eval "zfs send $TESTPOOL/src@1 | zfs recv -k $TESTPOOL/quick"
clonedup_sync
clonedup_check_shared $TESTPOOL/quick f $TESTPOOL/quick f2 "$all"
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/quick f ""
clonedup_kstat_is recv_runs 1
clonedup_kstat_is match_walks 0

# -K: the received copies land on a copy that was already there.
# Which one is not asserted.  Six copies of this content are in the
# pool by now, f and f2 in each of src, plain and quick, and the
# preference between them reads DCE_F_MAYBE_SHARED, which the index
# walk stores from brt_maybe_exists(), an approximate range check.
# What -K guarantees is that no block is stored again, so every
# block lands on one of the six.
log_must eval "zfs send $TESTPOOL/src@1 | zfs recv -K $TESTPOOL/rcv"
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
log_must [ $(zpool get -Hpo value bcloneused $TESTPOOL) -gt 0 ]

# an incremental with -K clones the blocks it brings
clonedup_write /$TESTPOOL/src/g
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@2
log_must eval \
    "zfs send -i @1 $TESTPOOL/src@2 | zfs recv -K $TESTPOOL/rcv"
clonedup_sync
clonedup_check_shared $TESTPOOL/src g $TESTPOOL/rcv g "$all"
clonedup_kstat_is recv_runs 3

# the next incremental applies without -F: the head was not modified
clonedup_write /$TESTPOOL/src/h
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@3
log_must eval \
    "zfs send -i @2 $TESTPOOL/src@3 | zfs recv $TESTPOOL/rcv"
clonedup_sync
log_must [ -f /$TESTPOOL/rcv/h ]

clonedup_leakcheck

log_pass \
    "zfs receive -k and -K clone received blocks before the snapshot"
