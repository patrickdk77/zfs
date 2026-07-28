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
#	Exercise FIEMAP hard: many files in a loop, a large multi-level file,
#	repeated queries that must be deterministic on an unchanging file, and
#	queries running concurrently with writers.  The block tree walk holds
#	the file range lock, so this stresses that path for leaks/hangs/panics.
#

verify_runnable "global"

claim="FIEMAP is stable under repeated, large, and concurrent use."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

# 1. Many small files, mapped back to back.
log_must mkdir /$TESTPOOL/many
for i in $(seq 1 200); do
	dd if=/dev/urandom of=/$TESTPOOL/many/f$i bs=8k count=1 status=none
done
log_must sync_pool $TESTPOOL
for i in $(seq 1 200); do
	log_must test "$(fiemap_mapped /$TESTPOOL/many/f$i)" -ge 1
done

# 2. A large multi-level file walks fully and is self-consistent: repeated
#    queries on an unchanging file return the identical extent count.
log_must dd if=/dev/urandom of=/$TESTPOOL/big bs=1M count=256
log_must sync_pool $TESTPOOL
typeset c1=$(fiemap_mapped /$TESTPOOL/big)
typeset c2=$(fiemap_mapped /$TESTPOOL/big)
log_must test "$c1" -ge 1
log_must test "$c1" -eq "$c2"

# 3. Hammer the same file many times; every call must succeed.
for i in $(seq 1 300); do
	log_must test -z "$(fiemap_errno /$TESTPOOL/big)"
done

# 4. FIEMAP concurrently with a writer appending to another file.  The range
#    lock is per file, so this must neither corrupt output nor wedge.
( for i in $(seq 1 400); do
	dd if=/dev/urandom of=/$TESTPOOL/writer bs=128k count=1 \
	    seek=$i conv=notrunc status=none
  done ) &
typeset wpid=$!
for i in $(seq 1 100); do
	log_must test -z "$(fiemap_errno /$TESTPOOL/big)"
done
wait $wpid

log_must zpool status -x $TESTPOOL

log_pass $claim
