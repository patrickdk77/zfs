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
#	FIEMAP handles sparse files correctly:
#	  - by default holes are omitted (a gap in the logical coverage);
#	  - with FIEMAP_FLAG_HOLES (-H) holes are reported as UNWRITTEN;
#	  - a fully sparse file maps nothing by default and one UNWRITTEN
#	    extent with -H.
#

verify_runnable "global"

claim="FIEMAP reports holes only when FIEMAP_FLAG_HOLES is requested."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

# 128k of data, a hole, then 128k of data at offset 9*128k.
log_must dd if=/dev/urandom of=/$TESTPOOL/sparse bs=128k count=1 seek=0
log_must dd if=/dev/urandom of=/$TESTPOOL/sparse bs=128k count=1 seek=9
log_must sync_pool $TESTPOOL

# Default: only the two data extents, hole is an implicit gap.
log_must test "$(fiemap_nr_extents /$TESTPOOL/sparse)" -eq 2
log_mustnot fiemap_has_flag unwritten /$TESTPOOL/sparse

# -H: the hole between them is reported as an UNWRITTEN extent.
log_must test "$(fiemap_nr_extents -H /$TESTPOOL/sparse)" -eq 3
log_must fiemap_has_flag unwritten -H /$TESTPOOL/sparse

# A fully sparse file.
log_must truncate -s 1M /$TESTPOOL/allhole
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_mapped /$TESTPOOL/allhole)" -eq 0
log_must test "$(fiemap_mapped -H /$TESTPOOL/allhole)" -eq 1
log_must fiemap_has_flag unwritten -H /$TESTPOOL/allhole

log_pass $claim
