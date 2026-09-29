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
#	Every value of zfs_clonedup_apply_order reaches the same
#	result.
#
# STRATEGY:
#	1. For each order, build a pool holding two sets of
#	   duplicates: three copies of one file, two of another.
#	   Three copies make a group with two destinations, which the
#	   ordered modes scatter and the checksum order keeps
#	   together.
#	2. Run clonedup and check the blocks are shared, the content
#	   is unchanged and zdb finds no leak.
#	3. The applied count and the bytes saved must match across
#	   all three orders.  The order decides what the apply
#	   touches first, never what it decides to do.
#

verify_runnable "global"

typeset -r CD_ORDER_DEFAULT=1
typeset -a applied saved

function cleanup
{
	log_must set_tunable32 CLONEDUP_APPLY_ORDER $CD_ORDER_DEFAULT
	clonedup_cleanup
}

log_assert "every apply order reaches the same result"
log_onexit cleanup

for order in 0 1 2; do
	clonedup_pool_create
	log_must set_tunable32 CLONEDUP_APPLY_ORDER $order

	clonedup_write /$TESTPOOL/a
	clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
	clonedup_dup /$TESTPOOL/a /$TESTPOOL/c
	clonedup_write /$TESTPOOL/d
	clonedup_dup /$TESTPOOL/d /$TESTPOOL/e
	clonedup_sync

	clonedup_run

	clonedup_check_shared $TESTPOOL a $TESTPOOL b \
	    "$(clonedup_all_blocks)"
	clonedup_check_shared $TESTPOOL a $TESTPOOL c \
	    "$(clonedup_all_blocks)"
	clonedup_check_shared $TESTPOOL d $TESTPOOL e \
	    "$(clonedup_all_blocks)"
	clonedup_stat_is $CDS_STATE $DSS_FINISHED
	clonedup_stat_is $CDS_ERRORS 0
	log_must cmp /$TESTPOOL/a /$TESTPOOL/b
	log_must cmp /$TESTPOOL/a /$TESTPOOL/c
	log_must cmp /$TESTPOOL/d /$TESTPOOL/e

	applied[$order]=$(clonedup_stat $CDS_APPLIED)
	saved[$order]=$(clonedup_stat $CDS_SAVED)
	log_note "order $order: applied ${applied[$order]}," \
	    "saved ${saved[$order]}"
	(( applied[order] == 3 * CD_BLOCKS )) ||
	    log_fail "order $order applied ${applied[$order]}," \
	        "wanted $((3 * CD_BLOCKS))"

	clonedup_leakcheck
	destroy_pool $TESTPOOL
done

for order in 1 2; do
	(( applied[order] == applied[0] )) ||
	    log_fail "order $order applied ${applied[$order]}," \
	        "order 0 applied ${applied[0]}"
	(( saved[order] == saved[0] )) ||
	    log_fail "order $order saved ${saved[$order]}," \
	        "order 0 saved ${saved[0]}"
done

log_pass "every apply order reaches the same result"
