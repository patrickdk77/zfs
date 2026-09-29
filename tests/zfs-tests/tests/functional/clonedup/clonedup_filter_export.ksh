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
#	Exporting a pool in the middle of a run frees the run's
#	counting filter.  A run allocates the filter when it starts
#	and keeps it until it ends, so a pool closed in between has
#	to release it with the rest of the run's memory.
#
# STRATEGY:
#	1. Force a counting filter of a size nothing else in the
#	   kernel allocates.
#	2. Start a run and hold it in its counting pass, so the
#	   filter is live.
#	3. Export and import.  The run restarts without a filter.
#	   Stop it, and repeat.
#	4. On Linux, the number of vmalloc areas of the filter's
#	   size must end where it started.
#

verify_runnable "global"

typeset -ri SHIFT=26
typeset -ri CYCLES=5

function cleanup
{
	log_must restore_tunable CLONEDUP_INDEX_FILTER
	log_must restore_tunable CLONEDUP_INDEX_FILTER_SHIFT
	poolexists $TESTPOOL || zpool import $TESTPOOL >/dev/null 2>&1
	clonedup_cleanup
}

# Live vmalloc areas of exactly this many pages.
function filter_areas # pages
{
	awk -v want="pages=$1" '{
		for (i = 1; i <= NF; i++) {
			if ($i == want)
				n++
		}
	} END { print n + 0 }' /proc/vmallocinfo
}

# A read of /proc/vmallocinfo is not atomic.  The list can change
# between the reads that page it out and a live area can be skipped,
# so a count is read up to ten times before it is taken as no higher.
function filter_live # pages floor
{
	typeset -i i n=0

	for ((i = 0; i < 10; i++)); do
		n=$(filter_areas $1)
		((n > $2)) && break
		sleep 0.1
	done
	echo $n
}

function vmalloc_used
{
	awk '$1 == "VmallocUsed:" { print $2 " " $3 }' /proc/meminfo
}

# The interrupted run was counting.  The restarted one indexes.
function wait_restarted # [timeout]
{
	typeset timeout=${1:-60}
	typeset i

	for ((i = 0; i < timeout * 10; i++)); do
		zpool status $TESTPOOL |
		    grep -q "indexing new data" && return 0
		sleep 0.1
	done
	log_fail "the run did not restart within $timeout seconds"
}

log_assert "an export frees the counting filter of a run in progress"
log_onexit cleanup
log_must save_tunable CLONEDUP_INDEX_FILTER
log_must save_tunable CLONEDUP_INDEX_FILTER_SHIFT

log_must set_tunable32 CLONEDUP_INDEX_FILTER 1
log_must set_tunable32 CLONEDUP_INDEX_FILTER_SHIFT $SHIFT

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_dup /$TESTPOOL/a /$TESTPOOL/b
clonedup_sync

# Two bits a slot, so the filter is a quarter of its slot count in
# bytes, from vmem_zalloc.
typeset -i fbytes fpages=0 base=0 before=0 live=0 after=0 leaked=0
((fbytes = (1 << SHIFT) / 4))

if is_linux; then
	((fpages = fbytes / $(getconf PAGESIZE)))
	base=$(filter_areas $fpages)
	log_note "vmalloc areas of $fpages pages: $base," \
	    "VmallocUsed $(vmalloc_used)"
else
	log_note "this platform has no per-allocation view of" \
	    "kernel memory, so the cycles run unmeasured"
fi

clonedup_hold
for ((i = 1; i <= CYCLES; i++)); do
	is_linux && before=$(filter_areas $fpages)
	log_must zpool clonedup $TESTPOOL
	clonedup_wait_running
	clonedup_stat_is $CDS_FILTER_SLOTS $((1 << SHIFT))

	# A count that cannot see a live filter would pass a leak.
	if is_linux; then
		live=$(filter_live $fpages $before)
		log_note "cycle $i: $before areas before the run," \
		    "$live with it"
		((live > before)) ||
		    log_fail "vmallocinfo does not show the filter"
	fi

	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	wait_restarted
	log_must zpool clonedup -s $TESTPOOL
done
clonedup_release

if is_linux; then
	after=$(filter_areas $fpages)
	((leaked = after - base))
	log_note "vmalloc areas of $fpages pages after $CYCLES" \
	    "cycles: $after, VmallocUsed $(vmalloc_used)"
	((leaked * 2 < CYCLES)) ||
	    log_fail "$leaked of $CYCLES counting filters outlived" \
	    "their pool"
fi

clonedup_leakcheck

log_pass "an export frees the counting filter of a run in progress"
