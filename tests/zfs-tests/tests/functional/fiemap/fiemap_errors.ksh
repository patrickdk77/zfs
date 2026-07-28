#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fiemap/fiemap.kshlib

#
# DESCRIPTION:
#	FIEMAP is only wired for regular files.  Requesting it on a directory
#	or a special file (fifo) fails cleanly with EOPNOTSUPP rather than
#	returning garbage or panicking the kernel.
#

verify_runnable "global"

claim="FIEMAP rejects non-regular files with EOPNOTSUPP."
log_assert $claim

typeset -r EOPNOTSUPP=95

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

# A directory has no fiemap inode op.
log_must mkdir /$TESTPOOL/dir
log_must test "$(fiemap_errno /$TESTPOOL/dir)" -eq $EOPNOTSUPP

# A fifo (special inode) likewise.
log_must mkfifo /$TESTPOOL/fifo
log_must test "$(fiemap_errno /$TESTPOOL/fifo)" -eq $EOPNOTSUPP

# The pool must still be healthy afterwards (no wedge/panic).
log_must zpool status -x $TESTPOOL

log_pass $claim
