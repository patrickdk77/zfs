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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
#	Cloning into a file as an unprivileged user drops its setid
#	bits and security.capability, as a write does on other
#	filesystems. Deduplication leaves them alone.
#
# STRATEGY:
#	1. Create a setuid and setgid file with a capability, owned by
#	   an unprivileged user
#	2. As that user, clone into it with FICLONE, FICLONERANGE and
#	   copy_file_range, and check that the bits and the capability
#	   are gone after each
#	3. As that user, dedupe identical data into it, and check that
#	   the bits and the capability are kept
#

verify_runnable "global"

claim="Cloning into a file drops its setid bits and capabilities."

log_assert $claim

typeset user=bcprivuser
typeset group=bcprivgrp
typeset d=/$TESTPOOL/d
typeset cap=0x0100000200200000000000000000000000000000

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
	del_user $user
	del_group $group
}

log_onexit cleanup

log_must add_group $group
log_must add_user $group $user

log_must zpool create -o feature@block_cloning=enabled $TESTPOOL \
    $DISKS
log_must mkdir $d
log_must chown $user:$group $d

log_must dd if=/dev/urandom of=$d/src bs=128K count=4
log_must chmod 644 $d/src

#
# Give $d/dst the contents of $d/src, mode 6755 and a capability.
#
function reset_dst
{
	log_must rm -f $d/dst
	log_must cp $d/src $d/dst
	log_must chown $user:$group $d/dst
	log_must chmod 6755 $d/dst
	log_must setfattr -n security.capability -v $cap $d/dst
	log_must sync_pool $TESTPOOL
}

function check_dropped # what
{
	typeset mode=$(stat -c %a $d/dst)
	if [[ "$mode" != 755 ]]; then
		log_fail "$1 left mode $mode, expected 755"
	fi
	if getfattr -n security.capability $d/dst >/dev/null 2>&1
	then
		log_fail "$1 left security.capability in place"
	fi
}

reset_dst
log_must user_run $user clonefile -c $d/src $d/dst
check_dropped FICLONE

reset_dst
log_must user_run $user clonefile -r $d/src $d/dst 0 0 131072
check_dropped FICLONERANGE

reset_dst
log_must user_run $user clonefile -f $d/src $d/dst 0 0 131072
check_dropped copy_file_range

reset_dst
log_must user_run $user clonefile -d $d/src $d/dst 0 0 131072
typeset mode=$(stat -c %a $d/dst)
if [[ "$mode" != 6755 ]]; then
	log_fail "FIDEDUPERANGE left mode $mode, expected 6755"
fi
log_must getfattr -n security.capability $d/dst

log_pass $claim
