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
#	Mapping a file while that same file is being written must be
#	safe and must not report a malformed map.
#
# STRATEGY:
#	The walk reads dn_phys and the block tree beneath it while
#	holding dn_struct_rwlock, having first synced the pool.  Writes
#	to the same file dirty that dnode again and spa_sync() then
#	rewrites its block pointers underneath the walk.  Racing the two
#	on one file is what exercises that; running them on separate
#	files, as the stress test does, never touches the same dnode.
#
#	Overlapping or duplicated extents are caught by assertions in a
#	debug build, so this doubles as a way to reach them.
#

verify_runnable "global"

claim="FIEMAP is safe while the same file is being written."
log_assert $claim

function cleanup
{
	[[ -n $wpid ]] && kill $wpid 2>/dev/null
	wait 2>/dev/null
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL $DISKS

F=/$TESTPOOL/racer
log_must dd if=/dev/urandom of=$F bs=1M count=64
log_must sync_pool $TESTPOOL

# Rewrite blocks throughout the file, and sync often, so the dnode is
# repeatedly dirtied and written out while the maps below run.
( typeset i=0
  while [[ $i -lt 400 ]]; do
	dd if=/dev/urandom of=$F bs=128k count=1 seek=$((RANDOM % 512)) \
	    conv=notrunc status=none 2>/dev/null
	(( i = i + 1 ))
	if [[ $((i % 32)) -eq 0 ]]; then
		sync_pool $TESTPOOL >/dev/null 2>&1
	fi
  done ) &
typeset wpid=$!

typeset i=0
while [[ $i -lt 150 ]]; do
	# The map may legitimately differ run to run; what must hold is
	# that the ioctl succeeds and describes something.
	log_must test -z "$(fiemap_errno $F)"
	log_must test "$(fiemap_mapped $F)" -ge 1
	(( i = i + 1 ))
done

wait $wpid
wpid=""

log_must sync_pool $TESTPOOL
log_must test -z "$(fiemap_errno $F)"
log_must zpool status -x $TESTPOOL
log_pass $claim
