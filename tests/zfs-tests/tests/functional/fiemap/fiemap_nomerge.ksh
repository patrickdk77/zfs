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
#	The ZFS-specific FIEMAP_FLAG_NOMERGE (-N) reports one extent per L0
#	block, whereas the default merges physically-contiguous blocks, so the
#	NOMERGE count is never smaller than the merged count and equals the
#	block count of the file.
#

verify_runnable "global"

claim="FIEMAP_FLAG_NOMERGE reports one extent per block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

# Small recordsize so a modest file has many blocks.
log_must zpool create -o feature@block_cloning=enabled -O recordsize=4k \
    $TESTPOOL $DISKS

# 16 blocks of 4k.
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16
log_must sync_pool $TESTPOOL

typeset merged=$(fiemap_nr_extents /$TESTPOOL/f)
typeset unmerged=$(fiemap_nr_extents -N /$TESTPOOL/f)

log_note "merged=$merged nomerge=$unmerged"
log_must test "$unmerged" -eq 16
log_must test "$merged" -le "$unmerged"

log_pass $claim
