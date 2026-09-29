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
#	The counting pre-pass is planned from what the last one
#	measured, and the decision does not alternate between runs.
#
# STRATEGY:
#	1. Cap the index small so it needs several partitions, which
#	   is the only shape where a pre-pass can pay.
#	2. Fill the pool mostly with duplicates, so the fraction the
#	   filter would keep is high and a pre-pass does not pay once
#	   that fraction is known.
#	3. Run three times on auto and compare the last two.  A run
#	   that declines measures nothing, so the next run has to use
#	   a measurement carried forward from an earlier one.
#	   Without it the decision alternates: on, off, on, off.
#	4. The measured fraction persists in the phys across a run
#	   that did not take a pre-pass.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_INDEX_FILTER
	log_must restore_tunable CLONEDUP_SCAN_MEM_MAX
	clonedup_cleanup
}

log_assert "the counting pre-pass decision is stable across runs"
log_onexit cleanup
log_must save_tunable CLONEDUP_INDEX_FILTER
log_must save_tunable CLONEDUP_SCAN_MEM_MAX

clonedup_pool_create

# Mostly duplicates.  A high keep fraction is what makes a pre-pass
# stop paying.  A fraction derived from candidates collapses once
# the duplicates are shared, and a planner using it keeps choosing
# a pre-pass that saves nothing.
clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_dup /$TESTPOOL/a /$TESTPOOL/c
clonedup_dup /$TESTPOOL/a /$TESTPOOL/d
clonedup_write /$TESTPOOL/unique
clonedup_sync

log_must set_tunable32 CLONEDUP_INDEX_FILTER 2
log_must set_tunable64 CLONEDUP_SCAN_MEM_MAX $((32 * 1024))

# Three full runs.  The first has nothing measured and may take a
# pre-pass from the model; that is allowed.  The two after it have a
# measurement and must agree with each other.
clonedup_run -f
typeset first_walks=$(clonedup_kstat count_walks)
clonedup_leakcheck

clonedup_run -f
typeset second_walks=$(clonedup_kstat count_walks)
typeset second_keep=$(clonedup_stat $CDS_KEEP_PCT)
clonedup_leakcheck

clonedup_run -f
typeset third_walks=$(clonedup_kstat count_walks)
typeset third_keep=$(clonedup_stat $CDS_KEEP_PCT)
clonedup_leakcheck

log_note \
    "count_walks per run: $first_walks $second_walks $third_walks"
log_note "keep_pct after runs two and three: $second_keep $third_keep"

if [[ "$second_walks" != "$third_walks" ]]; then
	log_fail "the pre-pass decision alternated: run two took" \
	    "$second_walks and run three took $third_walks. A run" \
	    "that declines records no measurement, so the decision" \
	    "must come from one that was carried forward."
fi

# The fraction outlives the run that measured it.  Without it the
# planner models one from candidates and the decision flips.
if (( first_walks > 0 && third_keep == 0 )); then
	log_fail "run one measured a keep fraction and run three" \
	    "reports none, so the measurement was not carried"
fi
if (( second_keep != third_keep )); then
	log_fail "the measured keep fraction changed between runs" \
	    "that both declined: $second_keep then $third_keep"
fi

# The result does not depend on any of this.
clonedup_check_shared $TESTPOOL a $TESTPOOL b "$(clonedup_all_blocks)"
clonedup_stat_is $CDS_ERRORS 0
log_must cmp /$TESTPOOL/a /$TESTPOOL/b
log_must cmp /$TESTPOOL/a /$TESTPOOL/c
log_must cmp /$TESTPOOL/a /$TESTPOOL/d

log_pass "the counting pre-pass decision is stable across runs"
