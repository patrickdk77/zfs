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
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
#	When FICLONE stops partway, it fails with the error that
#	stopped it, not EINVAL.
#
# STRATEGY:
#	1. Write a 16 MiB file in 4 KiB records and sync it, then
#	   rewrite only its last block, so that block alone is dirty.
#	2. With zfs_bclone_wait_dirty=0, FICLONE the file. The clone
#	   copies the clean blocks, stops at the dirty one, and must
#	   fail with EAGAIN.
#	3. Sync, FICLONE the file again, and check that the whole
#	   file was cloned.
#

verify_runnable "global"

claim="FICLONE reports the error that stopped a partial clone"

log_assert $claim

typeset errfile=$TEST_BASE_DIR/block_cloning_ficlone_short_error.err

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
	restore_tunable BCLONE_WAIT_DIRTY
	restore_tunable TXG_TIMEOUT
	rm -f $errfile
}

log_onexit cleanup

log_must save_tunable BCLONE_WAIT_DIRTY
log_must save_tunable TXG_TIMEOUT

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=4K $TESTPOOL $DISKS

log_must dd if=/dev/urandom of=/$TESTPOOL/file1 bs=4K count=4096
log_must sync_pool $TESTPOOL

log_must set_tunable32 TXG_TIMEOUT 600
log_must set_tunable32 BCLONE_WAIT_DIRTY 0
log_must dd if=/dev/urandom of=/$TESTPOOL/file1 bs=4K count=1 \
    seek=4095 conv=notrunc

clonefile -c /$TESTPOOL/file1 /$TESTPOOL/file2 2>$errfile
typeset -i rc=$?
log_note "clone of a file with a dirty tail returned $rc:" \
    "$(<$errfile)"
log_must [ $rc -ne 0 ]
log_mustnot grep -q "Invalid argument" $errfile
log_must grep -q "Resource temporarily unavailable" $errfile

log_must sync_pool $TESTPOOL
log_must clonefile -c /$TESTPOOL/file1 /$TESTPOOL/file3
log_must sync_pool $TESTPOOL
log_must have_same_content /$TESTPOOL/file1 /$TESTPOOL/file3
typeset blocks=$(get_same_blocks $TESTPOOL file1 $TESTPOOL file3)
log_must [ $(echo $blocks | wc -w) -eq 4096 ]

log_pass $claim
