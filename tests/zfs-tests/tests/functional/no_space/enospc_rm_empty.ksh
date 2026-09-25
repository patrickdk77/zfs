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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/no_space/enospc.cfg

#
# DESCRIPTION:
#	Empty files removed from a file system at its quota are
#	freed, not left in the unlinked set.
#
# STRATEGY:
#	1. Create a file system with a quota, and empty files in it.
#	2. Fill the rest of the quota, and snapshot the file system so
#	   that removing the files cannot take it below the quota.
#	3. Remove the files.
#	4. Verify that the unlinked set is empty.
#

verify_runnable "global"

function cleanup
{
	destroy_pool $TESTPOOL
}

function unlinked_left
{
	typeset -i adds=$(kstat_dataset $TESTPOOL/$TESTFS nunlinks)
	typeset -i dels=$(kstat_dataset $TESTPOOL/$TESTFS nunlinked)
	echo $((adds - dels))
}

log_onexit cleanup

claim="Empty files removed at the quota leave the unlinked set"

log_assert $claim

typeset -i n=1000

log_must zpool create -f $TESTPOOL $DISK_SMALL
log_must zfs create -o quota=16m -o recordsize=1m \
    -o mountpoint=$TESTDIR $TESTPOOL/$TESTFS
log_must mkdir $TESTDIR/d
log_must eval "seq -f '$TESTDIR/d/f%.0f' 1 $n | xargs touch"
log_mustnot file_write -o create -f $TESTDIR/fill -b 1048576 \
    -c 64 -d R
sync_pool $TESTPOOL
log_must zfs snapshot $TESTPOOL/$TESTFS@full
sync_pool $TESTPOOL
log_mustnot touch $TESTDIR/one-more
log_note "used $(get_prop used $TESTPOOL/$TESTFS)," \
    "quota $(get_prop quota $TESTPOOL/$TESTFS)"

log_must rm -rf $TESTDIR/d
sync_pool $TESTPOOL

typeset -i adds=$(kstat_dataset $TESTPOOL/$TESTFS nunlinks)
log_note "$adds objects added to the unlinked set"
log_must [ $adds -ge $n ]

typeset -i left=$(unlinked_left)
typeset -i i=0
while [ $left -gt 0 -a $i -lt 30 ]; do
	sleep 1
	left=$(unlinked_left)
	((i += 1))
done
log_note "$left objects still in the unlinked set"
log_must [ $left -eq 0 ]

log_pass $claim
