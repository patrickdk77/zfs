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
# Description:
# Forced ganging must not fail a block that is no larger than the
# smallest allocation size, since such a block cannot be ganged.
# Failing one suspends the pool.
#
# Strategy:
# 1. Create a pool with ashift=9, then one with ashift=12, and set
#    metaslab_force_ganging to 1 at 100 percent.
# 2. Write small files and sync. The pool must not suspend, and the
#    files must read back.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/gang_blocks/gang_blocks.kshlib

typeset fg0=$(get_tunable METASLAB_FORCE_GANGING)
typeset pct0=$(get_tunable METASLAB_FORCE_GANGING_PCT)

function reset_ganging
{
	set_tunable64 METASLAB_FORCE_GANGING $fg0
	set_tunable32 METASLAB_FORCE_GANGING_PCT $pct0
}

function cleanup2
{
	reset_ganging
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	cleanup
}

log_assert "Forced ganging leaves blocks too small to gang alone"
preamble
log_onexit cleanup2

for ashift in 9 12; do
	log_must zpool create -f -o ashift=$ashift $TESTPOOL $DISKS
	log_must zfs create $TESTPOOL/$TESTFS
	typeset mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)
	log_must zpool sync $TESTPOOL

	log_must set_tunable64 METASLAB_FORCE_GANGING 1
	log_must set_tunable32 METASLAB_FORCE_GANGING_PCT 100
	( for i in $(seq 1 50); do echo $i > $mntpnt/f$i; done
	    zpool sync $TESTPOOL ) &
	typeset pid=$!
	typeset health=""
	typeset -i n=0
	while kill -0 $pid 2>/dev/null && ((n < 60)); do
		health=$(zpool get -Ho value health $TESTPOOL)
		[[ $health == SUSPENDED ]] && break
		sleep 1
		((n++))
	done
	health=$(zpool get -Ho value health $TESTPOOL)
	reset_ganging
	if [[ $health == SUSPENDED ]]; then
		log_must zpool clear $TESTPOOL
		wait $pid
		log_fail "ashift=$ashift pool suspended"
	fi
	wait $pid || log_fail "ashift=$ashift writes failed"
	log_note "ashift=$ashift pool health: $health"

	for i in $(seq 1 50); do
		log_must test "$(cat $mntpnt/f$i)" = "$i"
	done
	log_must destroy_pool $TESTPOOL
done

log_pass "Forced ganging leaves blocks too small to gang alone"
