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
# A sequential reader of uncached data that starts at block 1 of a
# file with no prefetch stream gets a stream at its first read, so
# its reads of blocks 2 to 15 are prefetch hits.
#
# STRATEGY:
# 1. Write a file of 512 blocks of 128 KiB.
# 2. With prefetch=none, export and import the pool and read blocks 1
#    to 15, one block per read.  Fewer than 14 zfetchstats hits must
#    be counted, so that other activity cannot pass step 3.
# 3. With prefetch=all, do the same.  At least 14 hits, one for each
#    read of blocks 2 to 15, must be counted.
#

verify_runnable "global"

FILE=$TESTDIR/$TESTFILE0
typeset -i HITS=0

function cleanup
{
	zfs inherit prefetch $TESTPOOL/$TESTFS
	zfs inherit recordsize $TESTPOOL/$TESTFS
	zfs inherit compression $TESTPOOL/$TESTFS
	rm -f $FILE
}

#
# Export and import the pool, so that no block of FILE is cached,
# read blocks 1 to 15 of FILE and set HITS to the zfetchstats hits
# counted meanwhile.
#
function read_cold
{
	typeset -i h0

	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	h0=$(kstat zfetchstats.hits)
	log_must dd if=$FILE of=/dev/null bs=128k skip=1 count=15
	HITS=$(( $(kstat zfetchstats.hits) - h0 ))
}

log_assert "A cold read from block 1 starts a prefetch stream"
log_onexit cleanup

[[ $(get_tunable PREFETCH_DISABLE) -eq 0 ]] ||
    log_unsupported "zfs_prefetch_disable is set"

log_must zfs set recordsize=128k $TESTPOOL/$TESTFS
log_must zfs set compression=off $TESTPOOL/$TESTFS
log_must file_write -o create -f $FILE -b 131072 -c 512 -d R
sync_pool $TESTPOOL

log_must zfs set prefetch=none $TESTPOOL/$TESTFS
read_cold
log_note "prefetch=none: $HITS hits"
log_must test $HITS -lt 14

log_must zfs set prefetch=all $TESTPOOL/$TESTFS
read_cold
log_note "prefetch=all: $HITS hits"
log_must test $HITS -ge 14

log_pass "A cold read from block 1 starts a prefetch stream"
