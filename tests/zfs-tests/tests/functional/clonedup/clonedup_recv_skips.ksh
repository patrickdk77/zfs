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
#	zfs receive -k and -K refuse -c, each other and -A.  Where
#	the pass cannot run, the receive still succeeds, runs no pass
#	and warns on stderr without -v, with its own reason for each
#	cause.  The causes are a clonedup run holding the index,
#	clonedup=off or clonedup=source on the dataset, from its
#	parent or from -o, a raw stream, an encrypted dataset,
#	zfs_clonedup_apply_enabled or zfs_bclone_enabled set to 0,
#	and a pool without block_cloning.  Once nothing stands in
#	the way the pass runs, and -v reports it.
#

verify_runnable "global"

typeset stream=$TEST_BASE_DIR/clonedup_recv_skips.stream
typeset raw=$TEST_BASE_DIR/clonedup_recv_skips.raw
typeset part=$TEST_BASE_DIR/clonedup_recv_skips.part
typeset passphrase="clonedup-recv-skips"
typeset combo="invalid option combination"
typeset partds=$TESTPOOL/part

function cleanup
{
	log_must restore_tunable CLONEDUP_APPLY_ENABLED
	log_must restore_tunable BCLONE_ENABLED
	rm -f $stream $raw $part
	clonedup_cleanup
}

# zfs recv with args must fail and print want.
function skips_refused # want args...
{
	typeset want=$1 out

	shift
	out=$(zfs recv "$@" < $stream 2>&1) &&
	    log_fail "zfs recv $* succeeded: $out"
	log_note "zfs recv $*: $out"
	[[ $out == *"$want"* ]] ||
	    log_fail "zfs recv $*: want '$want'"
}

#
# Receive file into ds with -K and any further args.  The receive
# must succeed, run no pass and warn on stderr that the pass was
# skipped, and why.
#
function skips_skipped # file ds why [args...]
{
	typeset file=$1 ds=$2 why=$3 out
	typeset -i runs=$(clonedup_kstat recv_runs)

	shift 3
	out=$(zfs recv -K "$@" $ds < $file 2>&1 >/dev/null) ||
	    log_fail "receive into $ds failed: $out"
	log_note "receive into $ds: $out"
	typeset want="Warning: clonedup pass skipped on $ds: $why"
	[[ $out == *"$want"* ]] ||
	    log_fail "receive into $ds: want '$want'"
	clonedup_kstat_is recv_runs $runs
}

log_assert "zfs receive -k and -K refuse what they must, and warn" \
    "when the pass cannot run"
log_onexit cleanup
log_must save_tunable CLONEDUP_APPLY_ENABLED
log_must save_tunable BCLONE_ENABLED

clonedup_pool_create
log_must zfs create $TESTPOOL/src
clonedup_write /$TESTPOOL/src/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/src@1
log_must eval "zfs send $TESTPOOL/src@1 > $stream"

# the options that do not go together
skips_refused "$combo: -k and -K cannot be used with -c" \
    -K -c $TESTPOOL/src@1
skips_refused "$combo: -k and -K cannot be used with -c" \
    -k -c $TESTPOOL/src@1
skips_refused "$combo: -k and -K are mutually exclusive" \
    -k -K $TESTPOOL/kk
skips_refused "$combo: -k and -K are mutually exclusive" \
    -K -k $TESTPOOL/kk
log_mustnot datasetexists $TESTPOOL/kk

# -A takes neither, and leaves the partial receive alone
log_must eval "head -c $((CD_BS * CD_BLOCKS / 2)) $stream > $part"
log_mustnot eval "zfs recv -s $TESTPOOL/part < $part"
log_mustnot [ "$(get_prop receive_resume_token $partds)" = "-" ]
log_mustnot zfs recv -A -k $TESTPOOL/part
log_mustnot zfs recv -A -K $TESTPOOL/part
log_mustnot [ "$(get_prop receive_resume_token $partds)" = "-" ]
log_must zfs recv -A $TESTPOOL/part
log_mustnot datasetexists $TESTPOOL/part

# a running clonedup owns the index
clonedup_hold
log_must zpool clonedup $TESTPOOL
clonedup_wait_running
skips_skipped $stream $TESTPOOL/held \
    "a clonedup run or another receive's pass is running"
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/held f ""
clonedup_release
log_must zpool wait -t clonedup $TESTPOOL

# clonedup=off or clonedup=source on the dataset
log_must zfs create -o clonedup=off $TESTPOOL/off
skips_skipped $stream $TESTPOOL/off/rcv "the dataset has clonedup=off"
skips_skipped $stream $TESTPOOL/srcprop \
    "the dataset has clonedup=source" -o clonedup=source
skips_skipped $stream $TESTPOOL/offprop \
    "the dataset has clonedup=off" -o clonedup=off

# a raw stream, and a plain stream into an encrypted dataset
log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $TESTPOOL/enc"
clonedup_write /$TESTPOOL/enc/f
clonedup_sync
log_must zfs snapshot $TESTPOOL/enc@1
log_must eval "zfs send -w $TESTPOOL/enc@1 > $raw"
skips_skipped $raw $TESTPOOL/encrcv "the stream is raw"
skips_skipped $stream $TESTPOOL/enc/rcv "the dataset is encrypted"

# either switch off
log_must set_tunable32 CLONEDUP_APPLY_ENABLED 0
skips_skipped $stream $TESTPOOL/noapply \
    "the clonedup apply is disabled (zfs_clonedup_apply_enabled)"
log_must set_tunable32 CLONEDUP_APPLY_ENABLED 1
log_must set_tunable32 BCLONE_ENABLED 0
skips_skipped $stream $TESTPOOL/nobclone \
    "block cloning is disabled (zfs_bclone_enabled)"
log_must set_tunable32 BCLONE_ENABLED 1

# with nothing in the way the pass runs, and -v reports it
typeset out
out=$(zfs recv -v -K $TESTPOOL/rcv < $stream 2>&1) ||
    log_fail "receive into rcv failed: $out"
log_note "$out"
[[ $out == *"clonedup: "+([0-9])" blocks cloned"* ]] ||
    log_fail "the pass was not reported: $out"
[[ $out == *Warning* ]] && log_fail "the pass warned: $out"
clonedup_kstat_is recv_runs 1
clonedup_check_shared $TESTPOOL/src f $TESTPOOL/rcv f \
    "$(clonedup_all_blocks)"
clonedup_leakcheck

# a pool without block_cloning
log_must zpool destroy -f $TESTPOOL
log_must zpool create -f -o feature@block_cloning=disabled \
    -O compression=off $TESTPOOL $(clonedup_disks)
skips_skipped $stream $TESTPOOL/rcv \
    "the block_cloning feature is not enabled"
clonedup_leakcheck

log_pass "zfs receive -k and -K refuse what they must, and warn" \
    "when the pass cannot run"
