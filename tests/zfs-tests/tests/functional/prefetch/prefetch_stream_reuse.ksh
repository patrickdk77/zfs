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

#
# DESCRIPTION:
# With the default tunables on 64-bit systems, a file of 512 blocks
# of 128 KiB can have only one prefetch stream.
# When that stream is idle and far away, a sequential reader of
# uncached data that starts at block 1 takes it over at its first
# read, so its reads of blocks 2 to 15 are prefetch hits.
#
# STRATEGY:
# 1. Write a file of 512 blocks of 128 KiB.
# 2. With prefetch=none, run step 3 and check that fewer than 14
#    zfetchstats hits were counted for the reads of blocks 1 to 15,
#    so that other activity cannot pass step 3.
# 3. With prefetch=all, export and import the pool, read block 480,
#    which starts a stream at block 481, and read block 480 again,
#    which must count a hit.  Wait 3 seconds, so that the stream
#    has been idle for longer than zfetch_max_sec_reap, and read
#    blocks 1 to 15, one block per read.  At least 14 hits must be
#    counted.  The file stays open from the import on, so that its
#    dnode and the stream stay in memory.
#

verify_runnable "global"

FILE=$TESTDIR/$TESTFILE0
typeset -i FARHITS=0 HITS=0

function cleanup
{
	exec 3<&-
	zfs inherit prefetch $TESTPOOL/$TESTFS
	zfs inherit recordsize $TESTPOOL/$TESTFS
	zfs inherit compression $TESTPOOL/$TESTFS
	rm -f $FILE
}

#
# Read block 480 of FILE twice and set FARHITS to the hits counted
# for the second read, wait, read blocks 1 to 15 and set HITS to the
# hits counted for them.
#
function read_far_then_start
{
	typeset -i h0

	log_must dd if=$FILE of=/dev/null bs=128k skip=480 count=1
	h0=$(kstat zfetchstats.hits)
	log_must dd if=$FILE of=/dev/null bs=128k skip=480 count=1
	FARHITS=$(( $(kstat zfetchstats.hits) - h0 ))
	log_must sleep 3
	h0=$(kstat zfetchstats.hits)
	log_must dd if=$FILE of=/dev/null bs=128k skip=1 count=15
	HITS=$(( $(kstat zfetchstats.hits) - h0 ))
}

log_assert "A cold read from block 1 takes over an idle stream"
log_onexit cleanup

[[ $(get_tunable PREFETCH_DISABLE) -eq 0 ]] ||
    log_unsupported "zfs_prefetch_disable is set"

log_must zfs set recordsize=128k $TESTPOOL/$TESTFS
log_must zfs set compression=off $TESTPOOL/$TESTFS
log_must file_write -o create -f $FILE -b 131072 -c 512 -d R
sync_pool $TESTPOOL

log_must zfs set prefetch=none $TESTPOOL/$TESTFS
log_must_busy zpool export $TESTPOOL
log_must zpool import $TESTPOOL
exec 3<$FILE
read_far_then_start
exec 3<&-
log_note "prefetch=none: $FARHITS hits at 480, $HITS from 1"
log_must test $HITS -lt 14

log_must zfs set prefetch=all $TESTPOOL/$TESTFS
log_must_busy zpool export $TESTPOOL
log_must zpool import $TESTPOOL
exec 3<$FILE
read_far_then_start
exec 3<&-
log_note "prefetch=all: $FARHITS hits at 480, $HITS from 1"
log_must test $FARHITS -ge 1
log_must test $HITS -ge 14

log_pass "A cold read from block 1 takes over an idle stream"
