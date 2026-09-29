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
#	The scan record on disk names the scan queue object that the
#	current clonedup walk uses.  Every walk after the first one
#	replaces that object, so the record has to follow it.
#	Otherwise a pool exported in the middle of a run keeps an
#	object in the MOS that nothing references.
#
# STRATEGY:
#	1. Run once, then copy old data.  A default run then indexes
#	   the copy and walks the pool again to match it.
#	2. Park that run in its apply phase, after both walks.
#	3. The on-disk scan record names an existing scan queue.
#	4. Export.  zdb finds no leaked MOS object.
#	5. Import, let the restarted run finish, and check it.
#	6. The record names no queue, and zdb finds no leak.
#

verify_runnable "global"

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_ENABLED
	log_must restore_tunable CLONEDUP_INDEX_FILTER
	poolexists $TESTPOOL || zpool import $TESTPOOL >/dev/null 2>&1
	clonedup_cleanup
}

# scn_queue_obj, word 2 of the dsl_scan_phys_t saved as "scan".
function scan_queue_obj
{
	typeset out i

	zpool sync $TESTPOOL >/dev/null 2>&1
	for ((i = 0; i < 5; i++)); do
		out=$(zdb -dddd $TESTPOOL 1 2>/dev/null) && break
		sleep 1
	done
	echo "$out" |
	    awk '$1 == "scan" && $2 == "=" { print $5; exit }'
}

# zdb's MOS leak check.  -e reads the exported pool.
function mos_leakcheck # [-e]
{
	typeset out
	typeset -i rc

	out=$(zdb $1 -d $TESTPOOL 2>&1)
	rc=$?
	if echo "$out" | grep -q "^MOS object .* leaked"; then
		log_note "$(echo "$out" | grep "^MOS object")"
		log_fail "zdb found leaked MOS objects in $TESTPOOL"
	fi
	((rc == 0)) ||
	    log_fail "zdb $1 -d $TESTPOOL exited $rc: $out"
}

log_assert "the scan record follows the queue object of each walk"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_ENABLED
log_must save_tunable CLONEDUP_INDEX_FILTER

# No counting pass, so the second run's walks are index then match.
log_must set_tunable32 CLONEDUP_INDEX_FILTER 0

clonedup_pool_create
clonedup_write /$TESTPOOL/a
clonedup_sync
clonedup_run
clonedup_stat_is $CDS_APPLIED 0

clonedup_dup /$TESTPOOL/a /$TESTPOOL/c
clonedup_sync

log_must set_tunable32 CLONEDUP_APPLY_ENABLED 0
log_must zpool clonedup $TESTPOOL
clonedup_wait_applying
log_must [ $(clonedup_kstat match_walks) -gt 0 ]

typeset qobj=$(scan_queue_obj)
log_note "scan queue object on disk: '$qobj'"
log_must [ -n "$qobj" ]
log_must [ "$qobj" -ne 0 ]
log_must eval "zdb -dddd $TESTPOOL $qobj | grep -q 'scan work queue'"

log_must_busy zpool export $TESTPOOL
mos_leakcheck -e
log_must zpool import $TESTPOOL

log_must set_tunable32 CLONEDUP_APPLY_ENABLED 1
log_must zpool wait -t clonedup $TESTPOOL

clonedup_stat_is $CDS_STATE $DSS_FINISHED
clonedup_stat_is $CDS_APPLIED $CD_BLOCKS
clonedup_check_shared $TESTPOOL a $TESTPOOL c "$(clonedup_all_blocks)"

qobj=$(scan_queue_obj)
log_note "scan queue object on disk after the run: '$qobj'"
log_must [ "$qobj" = "0" ]

log_must_busy zpool export $TESTPOOL
mos_leakcheck -e
log_must zpool import $TESTPOOL

clonedup_leakcheck

log_pass "the scan record follows the queue object of each walk"
