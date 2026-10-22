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
#	A receive whose pass needs more than one index partition walks
#	the received dataset again after each apply.  Each later walk
#	starts only once the clones of the apply before it have
#	synced, so it never reads blocks those clones freed.  The pool
#	shows no checksum error, no data error and no ereport, before
#	and after a scrub, though another dataset is rewritten the
#	whole time.
#
# STRATEGY:
#	1. Build the pool as raidz1, or as a mirror on two disks.
#	2. Send a stream that holds two copies of 2048 8K blocks.
#	3. Cap the index at 64 KiB, far below what one partition
#	   would need, and run txgs every second.
#	4. Rewrite another dataset in the background, and receive the
#	   stream with -k.
#	5. Check that the pass split and cloned every copy, and that
#	   the pool and the data are intact.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_partitions.stream
typeset stop=$TEST_BASE_DIR/clonedup_recv_partitions.stop
typeset writer_pid=""
typeset -i nblk=2048 cap=65536
typeset -i ndisks=$(echo $(clonedup_disks) | wc -w)

function cleanup
{
	if [[ -n $writer_pid ]]; then
		touch $stop
		wait $writer_pid
	fi
	log_must restore_tunable CLONEDUP_SCAN_MEM_MAX
	log_must restore_tunable TXG_TIMEOUT
	log_must restore_tunable ZEVENT_LEN_MAX
	rm -f $stream $stop
	clonedup_cleanup
}

# Rewrite four files of another dataset until $stop appears.
function writer
{
	typeset -i i=0

	while [[ ! -f $stop ]] && kill -0 $$ 2>/dev/null; do
		dd if=/dev/urandom of=/$TESTPOOL/w/f$((i % 4)) bs=1M \
		    count=8 status=none
		((i += 1))
	done
}

#
# Every vdev ONLINE with no read, write or checksum error, and no
# data error.
#
function parts_check # when
{
	typeset t=$(zpool status -p $TESTPOOL | awk '
	    !NF { v = 0 }
	    v && NF >= 5 { print $1, $2, $3, $4, $5 }
	    $1 == "NAME" && $NF == "CKSUM" { v = 1 }')
	typeset -i nv=$(echo "$t" | wc -l)
	typeset -i ok=$(echo "$t" |
	    awk '$2 == "ONLINE" && $3 + $4 + $5 == 0' | wc -l)

	log_note "$1: vdevs: $(echo "$t" | tr '\n' ';')"
	(( nv > 0 && ok == nv )) ||
	    log_fail "$1: $ok of $nv vdevs clean"
	log_must eval "zpool status -v $TESTPOOL |" \
	    "grep -q 'errors: No known data errors'"
	log_mustnot eval "zpool events -H | grep -q ereport"
}

log_assert "a receive's pass walks again only after its clones synced"
log_onexit cleanup
log_must save_tunable CLONEDUP_SCAN_MEM_MAX
log_must save_tunable TXG_TIMEOUT
log_must save_tunable ZEVENT_LEN_MAX

if (( ndisks >= 3 )); then
	CD_VDEV=raidz1
elif (( ndisks == 2 )); then
	CD_VDEV=mirror
fi
clonedup_pool_create -O recordsize=8k
log_must zfs create $TESTPOOL/s
log_must dd if=/dev/urandom of=/$TESTPOOL/s/a bs=8k count=$nblk \
    status=none
log_must dd if=/$TESTPOOL/s/a of=/$TESTPOOL/s/b bs=8k status=none
clonedup_sync
log_must zfs snapshot $TESTPOOL/s@1
log_must eval "zfs send $TESTPOOL/s@1 > $stream"
log_must zfs create $TESTPOOL/w

log_must set_tunable32 ZEVENT_LEN_MAX 100000
log_must zpool events -c
log_must set_tunable64 CLONEDUP_SCAN_MEM_MAX $cap
log_must set_tunable32 TXG_TIMEOUT 1
typeset -i walks=$(clonedup_kstat index_walks)
rm -f $stop
writer &
writer_pid=$!

typeset out
out=$(zfs recv -v -k $TESTPOOL/r < $stream 2>&1) ||
    log_fail "zfs recv -k failed: $out"
log_note "$out"
log_must touch $stop
wait $writer_pid
writer_pid=""

typeset cloned=$(echo "$out" |
    awk '$1 == "clonedup:" && $3 == "blocks" { print $2 }')
log_note "cloned '$cloned', want $nblk"
[[ $cloned == $nblk ]] || log_fail "the pass did not clone every copy"
((walks = $(clonedup_kstat index_walks) - walks))
log_note "$walks index walks"
(( walks >= 2 )) || log_fail "the pass did not split"

parts_check "after the receive"
log_must cmp /$TESTPOOL/s/a /$TESTPOOL/r/a
log_must cmp /$TESTPOOL/s/b /$TESTPOOL/r/b
log_must zpool scrub -w $TESTPOOL
parts_check "after a scrub"
log_must cmp /$TESTPOOL/s/a /$TESTPOOL/r/a
clonedup_leakcheck

log_pass "a receive's pass walks again only after its clones synced"
