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
#	zfs receive -K makes its match walk while other datasets are
#	rewritten and their snapshots are taken and destroyed.  The
#	pool shows no checksum error, no data error and no vdev state
#	change afterwards, and again after an export, an import and a
#	scrub.  A destroy of a snapshot the walk holds fails with
#	EBUSY; that is logged and allowed.  Any other failure of the
#	churn fails the test.
#
#	This is a stress test, not a control.  A build whose walk
#	reads live datasets passes it too unless a stale read happens
#	to land during the run.
#
# STRATEGY:
#	1. Build the pool as raidz1, or as a mirror on two disks, so
#	   a read that fails its checksum on one child is repaired
#	   from the others.
#	2. Send a stream whose blocks a snapshot on the pool also
#	   holds, so each receive's pass has groups to apply.
#	3. In the background, rewrite part of a file in one of three
#	   datasets, snapshot that dataset and destroy its snapshot
#	   from two rounds back, over and over.
#	4. Receive the stream with -K into a new dataset, again and
#	   again, for about 20 seconds.
#	5. Check the vdevs and the event log, export, import, check,
#	   scrub and check again.
#

verify_runnable "global"

typeset data=$TEST_BASE_DIR/clonedup_recv_churn.data
typeset stream=$TEST_BASE_DIR/clonedup_recv_churn.stream
typeset stop=$TEST_BASE_DIR/clonedup_recv_churn.stop
typeset busy=$TEST_BASE_DIR/clonedup_recv_churn.busy
typeset fail=$TEST_BASE_DIR/clonedup_recv_churn.fail
typeset rounds=$TEST_BASE_DIR/clonedup_recv_churn.rounds
typeset churn_pid=""
typeset -i nchurn=3 churn_blks=2048 churn_bs=8192 nblk=64
typeset -i ndisks=$(echo $(clonedup_disks) | wc -w)

function cleanup
{
	if [[ -n $churn_pid ]]; then
		touch $stop
		wait $churn_pid
	fi
	log_must restore_tunable ZEVENT_LEN_MAX
	rm -f $data $stream $stop $busy $fail $rounds
	clonedup_cleanup
}

# Destroy a snapshot.  A failure goes to $busy or to $fail.
function churn_destroy # snap round
{
	typeset out

	out=$(zfs destroy $1 2>&1) && return
	if [[ $out == *"dataset is busy"* ]]; then
		echo "$1" >> $busy
	else
		echo "$2: destroy $1: $out" >> $fail
	fi
}

#
# Rewrite, snapshot and destroy until $stop appears.  A failure other
# than a busy destroy goes to $fail, and the number of rounds done to
# $rounds.
#
function churn
{
	typeset -i i=0 k off
	typeset ds out

	while [[ ! -f $stop ]] && kill -0 $$ 2>/dev/null; do
		((k = i % nchurn))
		ds=$TESTPOOL/c$k
		((off = RANDOM % (churn_blks - 64)))
		dd if=/dev/urandom of=/$ds/f bs=$churn_bs seek=$off \
		    count=64 conv=notrunc status=none ||
		    echo "$i: write to $ds failed" >> $fail
		out=$(zfs snapshot $ds@$i 2>&1) ||
		    echo "$i: snapshot $ds@$i: $out" >> $fail
		((i >= 2 * nchurn)) &&
		    churn_destroy $ds@$((i - 2 * nchurn)) $i
		((i += 1))
		echo $i > $rounds
	done
}

#
# Every vdev ONLINE with no read, write or checksum error, the vdev
# count unchanged, and no data error.
#
function churn_check # when
{
	typeset t=$(zpool status -p $TESTPOOL | awk '
	    !NF { v = 0 }
	    v && NF >= 5 { print $1, $2, $3, $4, $5 }
	    $1 == "NAME" && $NF == "CKSUM" { v = 1 }')
	typeset -i nv=$(echo "$t" | wc -l)
	typeset -i ok=$(echo "$t" |
	    awk '$2 == "ONLINE" && $3 + $4 + $5 == 0' | wc -l)

	log_note "$1: vdevs: $(echo "$t" | tr '\n' ';')"
	(( nv == ndisks + 2 && ok == nv )) ||
	    log_fail "$1: $ok of $nv vdevs clean," \
	    "want $((ndisks + 2))"
	log_must eval "zpool status -v $TESTPOOL |" \
	    "grep -q 'errors: No known data errors'"
}

#
# No ereport since the log was cleared.  The count of all events
# shows that the log was read.
#
function churn_events # when
{
	typeset ev=$(zpool events -H)
	typeset -i n=$(echo "$ev" | grep -c .)
	typeset er=$(echo "$ev" |
	    awk '$NF ~ /^ereport\./ { print $NF }' |
	    sort | uniq -c | tr '\n' ';')

	log_note "$1: $n events, ereports: '$er'"
	(( n > 0 )) || log_fail "$1: zpool events listed nothing"
	[[ -z $er ]] || log_fail "$1: ereports posted: $er"
}

log_assert "zfs receive -K leaves no error behind on a pool whose" \
    "datasets and snapshots change during its walk"
log_onexit cleanup
log_must save_tunable ZEVENT_LEN_MAX

if (( ndisks >= 3 )); then
	CD_VDEV=raidz1
elif (( ndisks == 2 )); then
	CD_VDEV=mirror
else
	log_unsupported "needs two disks"
fi
clonedup_pool_create
churn_check "created"

clonedup_write $data $nblk
log_must zfs create $TESTPOOL/src
clonedup_dup $data /$TESTPOOL/src/g
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"

typeset -i k
for ((k = 0; k < nchurn; k++)); do
	log_must zfs create -o recordsize=$churn_bs $TESTPOOL/c$k
	clonedup_write /$TESTPOOL/c$k/f $churn_blks $churn_bs
done
clonedup_sync
for ((k = 0; k < nchurn; k++)); do
	log_must zfs snapshot $TESTPOOL/c$k@base
done

# The churn posts an event or two a round, which would push the
# oldest out of a log of the default length.
log_must set_tunable32 ZEVENT_LEN_MAX 100000
log_must zpool events -c
rm -f $stop $busy $fail $rounds
churn &
churn_pid=$!

typeset -i n=0 nround=0
typeset -F start=$SECONDS
typeset out cloned
while (( SECONDS - start < 20 )) ||
    (( nround <= 2 * nchurn && SECONDS - start < 35 )); do
	out=$(zfs recv -v -K $TESTPOOL/r$n < $stream 2>&1) ||
	    log_fail "receive into r$n failed: $out"
	log_note "$out"
	cloned=$(echo "$out" |
	    awk '$1 == "clonedup:" && $3 == "blocks" { print $2 }')
	[[ -n $cloned ]] || log_fail "receive into r$n: no pass"
	(( cloned > 0 )) || log_fail "receive into r$n: none cloned"
	((n += 1))
	[[ -s $rounds ]] && nround=$(<$rounds)
done
log_must touch $stop
wait $churn_pid
churn_pid=""
[[ -s $rounds ]] && nround=$(<$rounds)

log_note "$n receives, $nround churn rounds"
(( nround > 2 * nchurn )) ||
    log_fail "the churn destroyed nothing in $nround rounds"
if [[ -s $busy ]]; then
	log_note "destroys refused as busy: $(echo $(<$busy))"
fi
[[ -s $fail ]] && log_fail "churn failures: $(<$fail)"

typeset -i m
for ((m = 0; m < n; m++)); do
	log_must cmp $data /$TESTPOOL/r$m/g
done
churn_check "after the receives"
churn_events "after the receives"

log_must_busy zpool export $TESTPOOL
log_must zpool import $TESTPOOL
churn_check "imported"
log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status $TESTPOOL |" \
    "grep -q 'scrub repaired 0B .* with 0 errors on'"
churn_check "scrubbed"
churn_events "scrubbed"
for ((m = 0; m < n; m++)); do
	log_must cmp $data /$TESTPOOL/r$m/g
done
clonedup_leakcheck

log_pass "zfs receive -K leaves no error behind on a pool whose" \
    "datasets and snapshots change during its walk"
