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
#	zfs receive -k turns every all-zero block the stream wrote
#	into a hole, the one it keeps as the source of the others
#	included, and counts each as a block it cloned.
#
# STRATEGY:
#	1. Write CD_BLOCKS all-zero blocks to a file without
#	   compression, snapshot it and send it.
#	2. Receive the stream with -k into a dataset without
#	   compression.
#	3. Check that the receive reports CD_BLOCKS blocks cloned,
#	   that the received file has no block left that holds data,
#	   that the punched kstat grew by CD_BLOCKS, and that the file
#	   still reads as zeros.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_zero.stream

function cleanup
{
	rm -f $stream
	clonedup_cleanup
}

# How many of a file's blocks hold data rather than a hole.
function rz_data_blocks # ds file
{
	zdb -vvvvv $1 -O $2 | awk '/ L0 / && /L\/[0-9a-f]+P/ { n++ }
	    END { print n + 0 }'
}

log_assert "zfs receive -k turns every all-zero block into a hole"
log_onexit cleanup

clonedup_pool_create
log_must zfs create $TESTPOOL/src
log_must dd if=/dev/zero of=/$TESTPOOL/src/z bs=$CD_BS \
    count=$CD_BLOCKS status=none
clonedup_sync
log_must [ $(rz_data_blocks $TESTPOOL/src z) -eq $CD_BLOCKS ]
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"

typeset -i punched=$(clonedup_kstat punched)
typeset -i runs=$(clonedup_kstat recv_runs)
typeset out
out=$(zfs recv -k -v $TESTPOOL/rcv < $stream) ||
    log_fail "zfs recv -k -v failed: $out"
log_note "zfs recv -k -v: $out"
[[ $out == *"clonedup: $CD_BLOCKS blocks cloned"* ]] ||
    log_fail "want $CD_BLOCKS blocks cloned"
# the holes are in an open txg when the receive returns
clonedup_sync
clonedup_kstat_is recv_runs $((runs + 1))
clonedup_kstat_is punched $((punched + CD_BLOCKS))
log_must [ $(rz_data_blocks $TESTPOOL/rcv z) -eq 0 ]
log_must cmp /$TESTPOOL/src/z /$TESTPOOL/rcv/z
clonedup_leakcheck

log_pass "zfs receive -k turns every all-zero block into a hole"
