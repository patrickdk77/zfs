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
#	FIEMAP reports the basic extent shape of a file:
#	  - a written file maps at least one extent, the last flagged LAST,
#	    and the logical extents fully cover the file;
#	  - an empty file maps zero extents;
#	  - a tiny file stored in an embedded block pointer is flagged INLINE.
#

verify_runnable "global"

claim="FIEMAP reports basic extent shape (written, empty, embedded)."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

# A written 512k file: fully covered, last extent flagged LAST.
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=128k count=4
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_nr_extents /$TESTPOOL/f)" -ge 1
log_must fiemap_has_flag last /$TESTPOOL/f
log_must test "$(fiemap_logical_sum /$TESTPOOL/f)" -eq 524288

# An empty file maps nothing.
log_must touch /$TESTPOOL/empty
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_mapped /$TESTPOOL/empty)" -eq 0
log_must test "$(fiemap_nr_extents /$TESTPOOL/empty)" -eq 0

# A tiny file lives in an embedded block pointer and is flagged INLINE.
log_must eval "printf '%50s' x > /$TESTPOOL/tiny"
log_must sync_pool $TESTPOOL
log_must fiemap_has_flag inline /$TESTPOOL/tiny
log_must fiemap_has_flag last /$TESTPOOL/tiny

log_pass $claim
