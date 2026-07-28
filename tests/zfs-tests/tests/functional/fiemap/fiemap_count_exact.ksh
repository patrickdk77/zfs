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
#	A buffer sized to exactly the counted number of extents returns the
#	whole map.  This is the count-then-fill sequence the FIEMAP docs
#	describe: ask with fm_extent_count == 0 to size an array, allocate
#	that many, then ask again.
#
#	The walk used to stop as soon as it held that many extents, so a
#	block that would have merged into the last one was never visited.
#	The map came back short and without LAST on its final extent, while
#	asking for one more returned the whole file.
#

verify_runnable "global"

claim="A buffer sized to the counted extents returns the whole map"

log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

#
# One disk on purpose. The bug needs the final two records to be
# adjacent so they merge, and a stripe hands them to different
# vdevs. Verified: on three disks this passes on a broken build.
#
typeset disk=$(echo $DISKS | awk '{print $1}')
log_must zpool create -O recordsize=128k -O compression=off $TESTPOOL $disk

typeset file=/$TESTPOOL/f

#
# Lay the file out so its last extent is one the walk cannot measure
# without looking past the caller's limit.
#
# Every other 128k record first, so holes keep them apart and each is
# its own extent.  Then a contiguous 1 MiB tail, which is eight records
# that have to merge into a single extent.  Reaching the limit on the
# first of those eight leaves seven more that belong to the same
# extent, so a walk that stops there reports it at an eighth of its
# real length and never reaches the end of the file.
#
# Relying on just the final two records being adjacent is not enough:
# whether they merge depends on allocation, and on some pools they do
# not.  Eight records written in one go do.
#
typeset -i i=0
while (( i < 60 )); do
	log_must dd if=/dev/urandom of=$file bs=128k count=1 seek=$i \
	    conv=notrunc
	(( i += 2 ))
done
log_must dd if=/dev/urandom of=$file bs=128k count=8 seek=60 conv=notrunc
log_must sync_pool $TESTPOOL

typeset -i cnt=$(fiemap_mapped -c 0 $file)
log_note "count request reports $cnt extents"
log_must test $cnt -ge 2

typeset -i exact=$(fiemap_nr_extents -c $cnt $file)
typeset -i more=$(fiemap_nr_extents -c $((cnt + 1)) $file)
log_note "asked $cnt got $exact, asked $((cnt + 1)) got $more"
log_must test $exact -eq $more

#
# The real signal. A short walk returns the same number of extents
# either way, because the block it never visited would have merged into
# the last one rather than adding to the count. What it cannot do is
# reach the end of the file, so LAST is missing.
#
log_must fiemap_has_flag last -c $cnt $file
log_must fiemap_has_flag last -c $((cnt + 1)) $file

log_pass $claim
