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
# A write that a zinject device rule fails is marked ZIO_FLAG_IO_RETRY.
# Clearing the rule while such a write is still in flight must not trip
# the IO_RETRY assertion in zio_dva_throttle_done().
#
# Strategy:
# 1. Create a single-disk pool, so the leaf vdev is also the top-level
#    vdev that the allocation throttle accounts to, and keep async
#    writes going.
# 2. 300 times, add a write-error rule at 10 percent, wait 0.2 seconds
#    and clear it. Every clear can land while a write the rule failed
#    has not finished.
# 3. Clear the pool's errors. The pool must be online.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/kstat.shlib

verify_runnable "global"

DISK1=${DISKS%% *}
typeset writing=$TEST_BASE_DIR/zinject_clear_inflight.$$

function cleanup
{
	rm -f $writing
	zinject -c all
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	wait
	default_cleanup_noexit
}

log_assert "Clearing a write-error rule with failed writes in flight"
log_onexit cleanup

log_must zpool create -f $TESTPOOL $DISK1
typeset mntpnt=$(get_prop mountpoint $TESTPOOL)

log_must touch $writing
for j in 1 2 3 4; do
	( while [[ -f $writing ]]; do
		dd if=/dev/urandom of=$mntpnt/w$j bs=128k count=128 \
		    2>/dev/null
	  done ) &
done

typeset -i injected=0
for i in $(seq 1 300); do
	log_must zinject -d $DISK1 -e io -T write -f 10 $TESTPOOL
	sleep 0.2
	# the rule's match and inject counts are the last two columns
	typeset mi=$(zinject | grep -m 1 -oE ' [0-9]+ +[0-9]+$')
	typeset n=${mi##* }
	injected=$((injected + ${n:-0}))
	log_must zinject -c all
	[[ $(kstat_pool $TESTPOOL state) == "SUSPENDED" ]] &&
	    log_must zpool clear $TESTPOOL
done

rm -f $writing
log_note "writes failed by the rule: $injected"
((injected > 0)) || log_fail "the rule failed no writes"
log_must zpool clear $TESTPOOL
wait
log_must zpool sync $TESTPOOL
log_must check_state $TESTPOOL "" "ONLINE"

log_pass "Clearing a write-error rule with failed writes in flight"
