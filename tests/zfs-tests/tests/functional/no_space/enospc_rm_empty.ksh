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
#	After empty files fill an encrypted file system, removing
#	them all finishes within a time limit.
#
# STRATEGY:
#	1. Create a small pool and an encrypted file system on it.
#	2. Create empty files until creation fails with ENOSPC.
#	3. Remove them all within 300 seconds.
#

verify_runnable "global"

function cleanup
{
	destroy_pool $TESTPOOL
}

log_onexit cleanup

claim="Empty files can be removed quickly from a full pool"

log_assert $claim

log_must zpool create -f $TESTPOOL $DISK_SMALL
log_must eval "echo password | zfs create -o encryption=on" \
    "-o keyformat=passphrase -o keylocation=prompt" \
    "-o mountpoint=$TESTDIR $TESTPOOL/$TESTFS"
log_must mkdir $TESTDIR/d

typeset -i n=0
while [ $n -lt 2000000 ]; do
	seq -f "$TESTDIR/d/f%.0f" $((n + 1)) $((n + 10000)) | \
	    xargs touch 2>/dev/null || break
	n=$((n + 10000))
done
log_note "created up to $n files before ENOSPC"
log_must [ $n -gt 0 ]
log_must [ $n -lt 2000000 ]
log_mustnot touch $TESTDIR/d/one-more
sync_pool $TESTPOOL

typeset -i start=$SECONDS
log_must timeout 300 rm -rf $TESTDIR/d
log_note "removed in $((SECONDS - start)) seconds"
log_must test -z "$(ls -A $TESTDIR)"

log_pass $claim
