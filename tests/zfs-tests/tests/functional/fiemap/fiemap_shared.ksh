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
#	FIEMAP marks block-cloned (BRT) extents SHARED and reports the same
#	physical offsets for the clone as the source, while an independent
#	copy of the same data is neither SHARED nor physically identical.
#

verify_runnable "global"

claim="FIEMAP flags block-cloned extents SHARED with matching physical offsets."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

log_must dd if=/dev/urandom of=/$TESTPOOL/src bs=128k count=4
log_must sync_pool $TESTPOOL

# A block clone shares the source's blocks.
log_must clonefile -f /$TESTPOOL/src /$TESTPOOL/clone 0 0 524288
log_must sync_pool $TESTPOOL

log_must fiemap_has_flag shared /$TESTPOOL/src
log_must fiemap_has_flag shared /$TESTPOOL/clone
log_must test "$(fiemap_physical /$TESTPOOL/src)" = \
    "$(fiemap_physical /$TESTPOOL/clone)"

# An independent copy (real data copy, not a clone) lands on different
# physical offsets than the source, and is not shared with anything.
#
# The SHARED flag is settled by an exact BRT entry lookup, not by the
# coarse brt_maybe_exists() range check on its own, so a freshly
# allocated block that happens to fall near cloned blocks must not be
# reported shared.
log_must dd if=/$TESTPOOL/src of=/$TESTPOOL/indep bs=128k
log_must sync_pool $TESTPOOL

log_mustnot test "$(fiemap_physical /$TESTPOOL/src)" = \
    "$(fiemap_physical /$TESTPOOL/indep)"
log_mustnot fiemap_has_flag shared /$TESTPOOL/indep

log_pass $claim
