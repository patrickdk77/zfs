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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fiemap/fiemap.kshlib

#
# DESCRIPTION:
#	A hole large enough to occupy a whole indirect block must be
#	reported, and the mapping must stay gap free across it.
#
# STRATEGY:
#	With a 128k record size an indirect block holds 1024 block
#	pointers and so spans 128 MiB.  Writing one record at offset 0
#	and another at 256 MiB leaves the entire second indirect block a
#	hole, whose block pointer sits at level 1.  A hole is an all zero
#	block pointer, so its level reads as 0; taking the level from the
#	block pointer rather than the bookmark mistakes such a hole for a
#	level 0 block, records it at the wrong offset and loses it, and
#	the 128 MiB it covers goes unreported.
#

verify_runnable "global"

claim="FIEMAP reports a hole that spans a whole indirect block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -O recordsize=128k -O compression=off $TESTPOOL $DISKS

f=/$TESTPOOL/bighole
log_must dd if=/dev/urandom of=$f bs=128k count=1 seek=0
log_must dd if=/dev/urandom of=$f bs=128k count=1 seek=2048 conv=notrunc
log_must sync_pool $TESTPOOL

# Two data extents, one at each end, with holes skipped by default.
log_must test "$(fiemap_nr_extents $f)" -eq 2

# With holes requested the map must cover every byte to EOF, so the
# logical lengths have to add up to the file size.  A lost hole shows
# up here as a shortfall.
size=$(stat -c %s $f)
log_must test "$(fiemap_logical_sum -H $f)" -eq $size

# The hole covering the second indirect block must be present.  It runs
# from 128 MiB to 256 MiB, so an extent has to start at or below 128 MiB
# and reach at least 256 MiB.
log_must eval "fiemap -H $f | awk '\$1 == \"ext\" && \$2 <= 134217728 && \
    \$2 + \$4 >= 268435456 { found = 1 } END { exit !found }'"

log_pass $claim
