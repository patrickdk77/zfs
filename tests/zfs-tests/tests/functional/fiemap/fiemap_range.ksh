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
#	A ranged FIEMAP query (start/length) reports only extents overlapping
#	the range, a sub-range never returns more extents than the whole file,
#	and a query starting beyond EOF returns nothing.
#

verify_runnable "global"

claim="FIEMAP restricts output to the requested logical range."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

# 1 MiB file == 8 x 128k blocks.
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=128k count=8
log_must sync_pool $TESTPOOL

typeset whole=$(fiemap_nr_extents /$TESTPOOL/f)

# A 256k window can only cover a few blocks; never more than the whole file.
typeset windowed=$(fiemap_nr_extents -s 262144 -l 262144 /$TESTPOOL/f)
log_must test "$windowed" -ge 1
log_must test "$windowed" -le "$whole"

# Starting past EOF (file is 1 MiB) returns nothing, no error.
log_must test "$(fiemap_mapped -s 2097152 /$TESTPOOL/f)" -eq 0
log_must test -z "$(fiemap_errno -s 2097152 /$TESTPOOL/f)"

log_pass $claim
