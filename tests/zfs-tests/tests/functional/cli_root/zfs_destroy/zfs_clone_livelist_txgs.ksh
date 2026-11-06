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

# DESCRIPTION
# Deleting a destroyed clone's livelist takes one txg per sublist.
# While the delete thread reads a sublist, txg_sync should not sync
# txgs back to back.
#
# STRATEGY
# 1. Write to a clone in 24 txgs, so its livelist has a sublist
#    for each.
# 2. Export and import the pool and delay every read by a second,
#    so the delete thread waits on each sublist. Without the delay
#    the delete is too short to count the extra txgs.
# 3. Destroy the clone and wait for the free to finish.
# 4. Check that the pool synced at least one txg per sublist and no
#    more than twice as many, plus 10.

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

function cleanup
{
	zinject -c all
	poolexists $TESTPOOL || zpool import $TESTPOOL
	zpool wait -t free $TESTPOOL
	datasetexists $TESTPOOL/$TESTFS1 && \
	    destroy_dataset $TESTPOOL/$TESTFS1 -R
	log_must restore_tunable LIVELIST_MAX_ENTRIES
	log_must restore_tunable LIVELIST_MIN_PERCENT_SHARED
}

function open_txg
{
	kstat_pool $TESTPOOL txgs | \
	    awk '$1 ~ /^[0-9]+$/ { txg = $1 } END { print txg }'
}

log_onexit cleanup

DISK=${DISKS%% *}
log_must zpool wait -t free $TESTPOOL

log_must save_tunable LIVELIST_MAX_ENTRIES
log_must save_tunable LIVELIST_MIN_PERCENT_SHARED
log_must set_tunable64 LIVELIST_MAX_ENTRIES 4
log_must set_tunable32 LIVELIST_MIN_PERCENT_SHARED -1

log_must zfs create $TESTPOOL/$TESTFS1
log_must zfs snapshot $TESTPOOL/$TESTFS1@snap
log_must zfs clone -o compression=off -o recordsize=128k \
    $TESTPOOL/$TESTFS1@snap $TESTPOOL/$TESTCLONE
for i in {1..24}; do
	log_must mkfile 1m /$TESTPOOL/$TESTCLONE/file$i
	sync_pool $TESTPOOL
done

sublists=$(zdb -vvvvv $TESTPOOL/$TESTCLONE | \
    awk '/Livelist:/ { print $(NF - 1) }')
(( sublists >= 20 )) || \
    log_fail "clone has ${sublists:-no} livelist sublists, want 20+"

log_must_busy zpool export $TESTPOOL
log_must zpool import $TESTPOOL
sync_pool $TESTPOOL
log_must zinject -d $DISK -D 1000:4 -T read $TESTPOOL

txg0=$(open_txg)
SECONDS=0
log_must zfs destroy $TESTPOOL/$TESTCLONE
log_must zpool wait -t free $TESTPOOL
typeset -i secs=$SECONDS
typeset -i txgs=$(( $(open_txg) - txg0 ))
log_must zinject -c all

log_note "$sublists sublists deleted in $secs s and $txgs txgs"
(( secs >= sublists / 2 )) || \
    log_fail "delete took $secs s, so sublist reads were not delayed"
(( txgs > sublists && txgs <= 2 * sublists + 10 )) || \
    log_fail "$txgs txgs for $sublists sublists, want" \
    "$((sublists + 1)) to $((2 * sublists + 10))"

log_pass "A livelist delete syncs about one txg per sublist."
