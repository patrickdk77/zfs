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
#	zfs receive -k makes the checks a clonedup run makes.  Its
#	pass clones nothing into an immutable file, and nothing into
#	a file whose owner is over its user quota.  A plain pair of
#	the same stream is cloned.
#
# STRATEGY:
#	1. In one filesystem write three files and a byte copy of
#	   each.  Make one pair immutable, give one to a user and set
#	   that user's quota below its usage, and leave the third.
#	2. Send a snapshot of it and receive the stream with -k.
#	3. Check that the received files kept their flags, owner and
#	   quota, that only the plain pair shares its blocks, that the
#	   pass cloned one block for each block of that pair, and that
#	   every file kept its content.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_policy.stream

function cleanup
{
	typeset ds

	for ds in $TESTPOOL/src $TESTPOOL/rcv; do
		datasetexists $ds || continue
		if is_freebsd; then
			chflags noschg /$ds/imm[ab] 2>/dev/null
		else
			chattr -i /$ds/imm[ab] 2>/dev/null
		fi
	done
	rm -f $stream
	clonedup_cleanup
}

# Note a count and fail unless it is above floor.
function rp_gt # what got floor
{
	log_note "$1: $2 (want more than $3)"
	clonedup_assert_counts "$2" "$3"
	log_must [ "$2" -gt "$3" ]
}

log_assert "zfs receive -k skips immutable and over-quota files"
log_onexit cleanup

clonedup_pool_create
typeset all="$(clonedup_all_blocks)"
typeset -A hash
typeset f c

log_must zfs create $TESTPOOL/src
for f in plain imm quo; do
	clonedup_write /$TESTPOOL/src/${f}a
	clonedup_sync
	clonedup_dup /$TESTPOOL/src/${f}a /$TESTPOOL/src/${f}b
	hash[$f]=$(xxh128digest /$TESTPOOL/src/${f}a)
done
log_must chown nobody /$TESTPOOL/src/quoa /$TESTPOOL/src/quob
if is_freebsd; then
	log_must chflags schg /$TESTPOOL/src/imma /$TESTPOOL/src/immb
else
	log_must chattr +i /$TESTPOOL/src/imma /$TESTPOOL/src/immb
fi
log_must zfs set userquota@nobody=512K $TESTPOOL/src
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"

typeset -i runs=$(clonedup_kstat recv_runs)
typeset -i clones=$(clonedup_kstat clones)
log_must eval "zfs recv -k $TESTPOOL/rcv < $stream"
# the clones are in an open txg when the receive returns
clonedup_sync
clonedup_kstat_is recv_runs $((runs + 1))

log_mustnot eval "echo x > /$TESTPOOL/rcv/immb"
rp_gt "usage of nobody" \
    "$(get_prop userused@nobody $TESTPOOL/rcv)" \
    "$(get_prop userquota@nobody $TESTPOOL/rcv)"

clonedup_check_shared $TESTPOOL/rcv plaina $TESTPOOL/rcv plainb "$all"
clonedup_check_shared $TESTPOOL/rcv imma $TESTPOOL/rcv immb ""
clonedup_check_shared $TESTPOOL/rcv quoa $TESTPOOL/rcv quob ""
clonedup_kstat_is clones $((clones + CD_BLOCKS))
for f in plain imm quo; do
	for c in a b; do
		log_must [ "$(xxh128digest /$TESTPOOL/rcv/$f$c)" = \
		    "${hash[$f]}" ]
	done
done
clonedup_leakcheck

log_pass "zfs receive -k skips immutable and over-quota files"
