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
. $STF_SUITE/tests/functional/direct/dio.cfg
. $STF_SUITE/tests/functional/direct/dio.kshlib

#
# DESCRIPTION:
#	A Direct I/O read of a block freed by a truncate that has not
#	synced yet must return zeros, not the old block's data.
#
# STRATEGY:
#	1. Write 1 MiB of random data and sync it.
#	2. With a long txg timeout, truncate the file to 128 KiB and
#	   back to 1 MiB, so the blocks past 128 KiB have a pending
#	   free while their block pointers are still valid on disk.
#	3. Read the file with O_DIRECT. Everything past 128 KiB must
#	   be zero.
#	4. Sync and read it again with O_DIRECT.
#

verify_runnable "global"

mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)
typeset file=$mntpnt/pending_free
typeset out=$mntpnt/pending_free.out
typeset zeros=$mntpnt/pending_free.zero

function cleanup
{
	restore_tunable TXG_TIMEOUT
	rm -f $file $out $zeros $zeros.cmp
}

function check_tail
{
	typeset what=$1

	log_must rm -f $out
	log_must stride_dd -i $file -o $out -b 131072 -c 8 -d
	log_must stride_dd -i $out -o $zeros.cmp -b 131072 -c 7 -p 1
	cmp -s $zeros.cmp $zeros || \
	    log_fail "$what: Direct I/O read stale data past the truncate"
	rm -f $zeros.cmp
}

log_assert "Direct I/O reads a block with a pending free as zeros"
log_onexit cleanup

log_must stride_dd -i /dev/zero -o $zeros -b 131072 -c 7
log_must stride_dd -i /dev/urandom -o $file -b 131072 -c 8
log_must sync_pool $TESTPOOL

log_must save_tunable TXG_TIMEOUT
log_must set_tunable64 TXG_TIMEOUT 300
log_must sync_pool $TESTPOOL

log_must truncate -s 131072 $file
log_must truncate -s 1048576 $file
check_tail "before sync"

log_must sync_pool $TESTPOOL
check_tail "after sync"

log_pass "Direct I/O reads a block with a pending free as zeros"
