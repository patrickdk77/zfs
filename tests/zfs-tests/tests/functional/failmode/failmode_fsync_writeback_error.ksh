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
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#
. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	syncfs reports an fsync failure after the pool recovers.
#
# STRATEGY:
#	1. Write to a file and keep it open without syncing
#	2. Fail the device, then fsync, which must fail
#	3. Repair the device, then syncfs, which must report the error
#	4. A second syncfs must succeed
#

verify_runnable "global"

if [[ $(linux_version) -lt $(linux_version "5.8") ]]; then
	log_unsupported "syncfs(2) reports errors since Linux 5.8"
fi

log_assert "A writeback error is reported by the next syncfs"

typeset failsent=$TEST_BASE_DIR/fsync_wb_fail.$$
typeset healsent=$TEST_BASE_DIR/fsync_wb_heal.$$
typeset -i helper_pid=0

function cleanup
{
	zinject -c all || true
	test $helper_pid -gt 0 && kill -9 $helper_pid 2>/dev/null
	rm -f $failsent $healsent
	zpool clear $TESTPOOL || true
	destroy_pool $TESTPOOL
}
log_onexit cleanup

DISK=${DISKS%% *}
rm -f $failsent $healsent

log_must zpool create -o failmode=continue -f $TESTPOOL $DISK
log_must zfs create -o recordsize=128k $TESTPOOL/$TESTFS

typeset datafile=/$TESTPOOL/$TESTFS/datafile

#
# Create the ZIL head now.  Its first use waits for a txg sync, which
# would race with the fault injection.
#
log_must dd if=/dev/zero of=$datafile bs=128k count=1 conv=fsync
log_must zpool sync

#
# The sentinels live outside the pool, which cannot be written while
# the faults are injected.
#
fsync_writeback_error $datafile $failsent $healsent &
helper_pid=$!

function wait_for # path
{
	typeset -i tries=50
	until [[ -e $1 ]]; do
		if ((tries-- == 0)); then
			log_fail "helper never reached $1"
		fi
		sleep 0.2
	done
}

wait_for $failsent
log_must zinject -d $DISK -e io -T write $TESTPOOL
log_must zinject -d $DISK -e nxio -T probe $TESTPOOL
log_must rm -f $failsent

wait_for $healsent
log_must zinject -c all
log_must zpool clear $TESTPOOL
log_must rm -f $healsent

wait $helper_pid
typeset -i rc=$?
helper_pid=0
log_note "helper returned $rc"

if ((rc == 1)); then
	log_fail "syncfs did not report the writeback error"
fi
if ((rc != 0)); then
	log_fail "helper failed for its own reasons, rc=$rc"
fi

log_pass "A writeback error is reported by the next syncfs"
