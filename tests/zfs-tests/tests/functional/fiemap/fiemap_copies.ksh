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
#	By default FIEMAP reports only the first DVA of each block.  With the
#	ZFS-specific FIEMAP_FLAG_COPIES (-C), all ditto copies are reported as
#	overlapping logical extents at distinct physical offsets.
#

verify_runnable "global"

claim="FIEMAP_FLAG_COPIES reports every ditto copy of a block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS
log_must zfs create -o copies=2 $TESTPOOL/c2

log_must dd if=/dev/urandom of=/$TESTPOOL/c2/f bs=128k count=1
log_must sync_pool $TESTPOOL

# Default: one extent (first copy only).
log_must test "$(fiemap_nr_extents /$TESTPOOL/c2/f)" -eq 1

# -C: both copies, same logical offset, different physical offsets.
log_must test "$(fiemap_nr_extents -C /$TESTPOOL/c2/f)" -eq 2
typeset phys=$(fiemap_physical -C /$TESTPOOL/c2/f)
typeset p1=$(echo $phys | awk '{print $1}')
typeset p2=$(echo $phys | awk '{print $2}')
log_mustnot test "$p1" = "$p2"

log_pass $claim
