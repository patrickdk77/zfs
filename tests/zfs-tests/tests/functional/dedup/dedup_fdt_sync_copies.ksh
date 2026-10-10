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
# DESCRIPTION:
#	A block that dmu_sync() wrote for a copies=2 file system, whose
#	data matches a fast dedup entry with one copy, reads back intact.
#
# STRATEGY:
#	1. Write a compressible file to a copies=1 file system with dedup
#	   on, and sync.
#	2. Write the same data to a copies=2 file system with dedup on,
#	   logbias=throughput and sync=always, so that dmu_sync() writes
#	   each block before its txg syncs.
#	3. Sync, export and import the pool, and check that both files
#	   read back the same data and that a scrub repairs nothing.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

log_assert "a dmu_sync() block that matches a smaller FDT entry" \
    "reads back intact"

typeset src=$TEST_BASE_DIR/dedup_fdt_sync_copies.src

function cleanup
{
	destroy_pool $TESTPOOL
	rm -f $src
	log_must restore_tunable DEDUP_LOG_TXG_MAX
}

log_onexit cleanup

log_must save_tunable DEDUP_LOG_TXG_MAX
log_must set_tunable32 DEDUP_LOG_TXG_MAX 1

log_must eval "seq -f 'dedup_fdt_sync_copies %08g' 1 200000 |" \
    "head -c 4194304 > $src"

log_must zpool create -f -o feature@fast_dedup=enabled \
    $TESTPOOL $DISKS

log_must zfs create -o dedup=on -o compression=lz4 -o copies=1 \
    -o recordsize=128k $TESTPOOL/one
log_must dd if=$src of=/$TESTPOOL/one/file bs=128k
log_must sync_pool $TESTPOOL

log_must zfs create -o dedup=on -o compression=lz4 -o copies=2 \
    -o recordsize=128k -o logbias=throughput -o sync=always \
    $TESTPOOL/two
log_must dd if=$src of=/$TESTPOOL/two/file bs=128k
log_must sync_pool $TESTPOOL

log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
log_must cmp $src /$TESTPOOL/one/file
log_must cmp $src /$TESTPOOL/two/file
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"
log_must eval "zpool status $TESTPOOL | grep -q 'scrub repaired 0B'"

log_pass "a dmu_sync() block that matches a smaller FDT entry" \
    "reads back intact"
