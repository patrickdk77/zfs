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
#	FIEMAP flags compressed extents ENCODED and leaves incompressible
#	extents unflagged, even on a dataset with compression enabled.
#

verify_runnable "global"

claim="FIEMAP flags compressed extents ENCODED."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS
log_must zfs create -o compression=lz4 $TESTPOOL/comp

# Highly compressible data -> every extent ENCODED.
# Constant-fill data compresses well under lz4 but is not zeroes, so the
# blocks stay allocated rather than becoming holes.  file_write is used
# because it is always present in the constrained ZTS PATH.
log_must file_write -o create -f /$TESTPOOL/comp/z -b 131072 -c 8 -d 1
log_must sync_pool $TESTPOOL
log_must fiemap_all_flag encoded /$TESTPOOL/comp/z

# Incompressible data on the same dataset is stored raw -> not ENCODED.
log_must dd if=/dev/urandom of=/$TESTPOOL/comp/r bs=128k count=8
log_must sync_pool $TESTPOOL
log_mustnot fiemap_has_flag encoded /$TESTPOOL/comp/r

# A compressed extent's physical length is its PSIZE, which is smaller
# than the logical record and not a multiple of the block size, so it
# must also be flagged NOT_ALIGNED.  Without that a caller like
# filefrag, which divides the physical offset by the block size, would
# present the result as if it were a plain device range; several
# compressed extents can share one such block.
log_must fiemap_all_flag not_aligned /$TESTPOOL/comp/z

# Compression must not lose coverage: the logical lengths still have to
# account for the whole file.
zsize=$(stat -c %s /$TESTPOOL/comp/z)
log_must test "$(fiemap_logical_sum -H /$TESTPOOL/comp/z)" -eq $zsize

log_pass $claim
