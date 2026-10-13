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
# A clone received from a non-raw "zfs send -p" stream takes its
# encryption from its origin, so zfs receive must not try to set
# encryption=off on it. A user without the "encryption" permission
# is refused that, and root is left with a local encryption property.
#
# Strategy:
# 1. Create a filesystem, snapshot it, clone the snapshot and snapshot
#    the clone. Receive the filesystem snapshot as the clone's origin.
# 2. As root, receive the clone from "zfs send -p -i". The received
#    clone must not have a local encryption property.
# 3. Allow a user to create, mount and receive, and receive the clone
#    as that user from "zfs send -p -i" and from "zfs send -pR". Both
#    must succeed and print no error.
#

. $STF_SUITE/tests/functional/delegate/delegate_common.kshlib

verify_runnable "both"

typeset src=$TESTPOOL/rc_src
typeset clone=$TESTPOOL/rc_clone
typeset dst=$TESTPOOL/rc_dst
typeset inc=$TEST_BASE_DIR/rc_inc.$$
typeset rep=$TEST_BASE_DIR/rc_rep.$$

function cleanup
{
	destroy_dataset $dst "-Rf"
	destroy_dataset $src "-Rf"
	rm -f $inc $rep
}

# user_recv STREAM TARGET: receive as $STAFF1 and fail on any error.
function user_recv
{
	typeset stream=$1
	typeset target=$2

	log_must user_run $STAFF1 "zfs receive -u $target < $stream"
	if grep -q "cannot receive" $TEST_BASE_DIR/err; then
		log_fail "$STAFF1 receive of $target: $(<$TEST_BASE_DIR/err)"
	fi
	log_must datasetexists $target@b
}

log_assert "A user allowed to receive can receive a clone with -p"
log_onexit cleanup

log_must zfs create $src
log_must eval "echo a > $(get_prop mountpoint $src)/f"
log_must zfs snapshot $src@a
log_must zfs clone $src@a $clone
log_must eval "echo b > $(get_prop mountpoint $clone)/f"
log_must zfs snapshot $clone@b

log_must zfs create $dst
log_must eval "zfs send -p $src@a | zfs receive -u $dst/src"
log_must eval "zfs send -p -i $src@a $clone@b > $inc"
log_must eval "zfs send -pR $clone@b > $rep"
log_must chmod 644 $inc $rep

log_must eval "zfs receive -u $dst/clroot < $inc"
typeset esrc=$(zfs get -H -o source encryption $dst/clroot)
log_note "encryption source on $dst/clroot: $esrc"
[[ $esrc == "local" ]] &&
	log_fail "receive set encryption locally on clone $dst/clroot"

log_must zfs allow $STAFF1 \
    create,destroy,mount,mountpoint,receive,rollback,userprop $dst
user_recv $inc $dst/clinc
user_recv $rep $dst/clrep

log_pass "A user allowed to receive can receive a clone with -p"
