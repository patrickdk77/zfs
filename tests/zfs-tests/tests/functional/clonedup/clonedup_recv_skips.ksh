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
#	A receive with -K leaves the stream alone when the pass cannot
#	run: while a clonedup scan holds the pool, for a dataset with
#	clonedup=off, and for an encrypted raw stream.  The receive
#	itself succeeds every time, -k and -K refuse -c and each
#	other, and once nothing stands in the way the pass runs.
#

verify_runnable "global"

log_assert \
    "zfs receive -K skips the pass where it must and still receives"
log_onexit clonedup_cleanup

typeset stream=$TEST_BASE_DIR/clonedup_recv.stream
typeset passphrase="clonedup-recv-skips"

clonedup_pool_create
log_must zfs create $TESTPOOL/src
clonedup_write /$TESTPOOL/src/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"

# the flags that do not go together
log_mustnot eval "zfs recv -K -c $TESTPOOL/src@1 < $stream"
log_mustnot eval "zfs recv -k -c $TESTPOOL/src@1 < $stream"

# a running clonedup owns the index: the receive completes and skips
# its pass
clonedup_hold
log_must zpool clonedup $TESTPOOL
clonedup_wait_running
typeset out
out=$(zfs recv -v -K $TESTPOOL/held < $stream 2>&1) ||
    log_fail "receive into held failed: $out"
log_note "$out"
[[ $out == *"clonedup: pass skipped: a clonedup run"* ]] ||
    log_fail "the skipped pass was not reported: $out"
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/held f ""
clonedup_kstat_is recv_runs 0
clonedup_release
log_must zpool wait -t clonedup $TESTPOOL

# clonedup=off on the target
log_must zfs create -o clonedup=off $TESTPOOL/off
out=$(zfs recv -v -K $TESTPOOL/off/rcv < $stream 2>&1) ||
    log_fail "receive into off failed: $out"
log_note "$out"
[[ $out == *"clonedup: pass skipped: the stream or the dataset"* ]] ||
    log_fail "the skipped pass was not reported: $out"
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/off/rcv f ""
clonedup_kstat_is recv_runs 0

# an encrypted raw stream
log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $TESTPOOL/enc"
clonedup_write /$TESTPOOL/enc/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/enc@1
log_must eval \
    "zfs send -w $TESTPOOL/enc@1 | zfs recv -K $TESTPOOL/encrcv"
clonedup_kstat_is recv_runs 0

# with nothing in the way the pass runs
out=$(zfs recv -v -K $TESTPOOL/rcv < $stream 2>&1) ||
    log_fail "receive into rcv failed: $out"
log_note "$out"
[[ $out == *"blocks cloned"* && $out != *"pass skipped"* ]] ||
    log_fail "the pass was not reported: $out"
clonedup_kstat_is recv_runs 1
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/rcv f \
    "$(clonedup_all_blocks)"

log_must rm -f $stream
clonedup_leakcheck

log_pass \
    "zfs receive -K skips the pass where it must and still receives"
