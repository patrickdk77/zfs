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
. $STF_SUITE/tests/functional/rsend/rsend.kshlib
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
# zfs recv -n reads through a -k stream, CLONE records included,
# without receiving anything.
#
# STRATEGY:
# 1. Write a file and clone it, snapshot, send with -k.
# 2. zfs recv -n succeeds and creates nothing.
# 3. The same for a -R -k replication stream.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cdr -r
	rm -f $BACKDIR/cdr-full $BACKDIR/cdr-repl
}

log_assert "zfs recv -n accepts a stream with CLONE records"
log_onexit cleanup

typeset src=$POOL/cdr

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/f1 bs=128k count=4
log_must sync_pool $POOL
log_must clonefile -f $mnt/f1 $mnt/f2
log_must sync_pool $POOL
log_must zfs snapshot $src@s

log_must eval "zfs send -k $src@s > $BACKDIR/cdr-full"
log_must [ "$(stream_clone_records $BACKDIR/cdr-full)" = "4" ]
log_must eval "zfs recv -n $POOL2/cdr < $BACKDIR/cdr-full"
log_mustnot datasetexists $POOL2/cdr

log_must eval "zfs send -R -k $src@s > $BACKDIR/cdr-repl"
log_must eval "zfs recv -n -d $POOL2 < $BACKDIR/cdr-repl"
log_mustnot datasetexists $POOL2/cdr

log_pass "zfs recv -n accepts a stream with CLONE records"
