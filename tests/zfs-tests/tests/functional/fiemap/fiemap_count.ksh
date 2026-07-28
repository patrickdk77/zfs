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
#	FIEMAP honors the caller's extent-buffer size:
#	  - fm_extent_count == 0 counts extents without copying any out;
#	  - a buffer smaller than the extent count returns a partial result
#	    and does not set LAST on the final returned extent.
#

verify_runnable "global"

claim="FIEMAP honors fm_extent_count (count-only and partial fills)."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

# Two data regions separated by a hole.  The hole guarantees at least two
# data extents no matter how contiguously the allocator packs the blocks:
# a single sequential write can be laid out contiguously and merged into
# one extent, but a hole is never merged across, so this stays deterministic
# across platforms and pool geometries.
log_must zpool create -o feature@block_cloning=enabled -O recordsize=4k \
    $TESTPOOL $DISKS
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16 seek=48
log_must sync_pool $TESTPOOL

# Full read establishes the true extent count.
typeset full=$(fiemap_mapped /$TESTPOOL/f)
log_must test "$full" -ge 2

# Count-only mode (-c 0): reports the count, copies out no extents.
log_must test "$(fiemap_mapped -c 0 /$TESTPOOL/f)" -eq "$full"
log_must test "$(fiemap_nr_extents -c 0 /$TESTPOOL/f)" -eq 0

# Partial fill (buffer of 1): exactly one extent, and NOT flagged LAST since
# more extents remain.
log_must test "$(fiemap_nr_extents -c 1 /$TESTPOOL/f)" -eq 1
log_mustnot fiemap_has_flag last -c 1 /$TESTPOOL/f

log_pass $claim
