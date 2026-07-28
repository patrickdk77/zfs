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
#	A clone must be visible to FIEMAP as soon as it returns, not
#	only once the next TXG has synced.
#
# STRATEGY:
#	A clone's references land in the BRT pending tree and only
#	reach bv_entcount, bv_tree and the ZAP when brt_pending_apply()
#	runs in syncing context.  Cloning out of a file does not dirty
#	the source's dnode, so FIEMAP takes no sync for it, and a
#	source mapped before that TXG reported the cloned range as not
#	shared while the destination, whose dnode the clone did dirty,
#	forced the sync and reported it shared.  One block, two
#	answers, decided by which file was asked first.
#
#	Clone the second of two records and map the source with
#	nothing in between: the first record must be unshared and the
#	second shared.  Order matters, so the source is mapped first
#	and the destination is not mapped until afterwards; mapping
#	the destination first would force the sync and hide this.
#

verify_runnable "global"

claim="FIEMAP reports a clone as shared before its TXG syncs."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    -O compression=off $TESTPOOL $DISKS

SRC=/$TESTPOOL/src
DST=/$TESTPOOL/dst

# Two full records, fully synced, so mapping the source takes no sync
# of its own and the BRT is the only thing that can change the answer.
log_must dd if=/dev/urandom of=$SRC bs=128k count=2
log_must sync_pool $TESTPOOL

# Nothing is shared yet.
log_mustnot fiemap_has_flag shared $SRC

# Clone only the second record.  No sync after this point.
log_must clonefile -r $SRC $DST 131072 0 131072

# The source must already show the second record shared and the first
# not, with no sync in between.
log_must eval "fiemap $SRC | awk '
    \$1 == \"ext\" && \$2 == 0       { if (\$0 ~ /shared/) bad = 1; seen0 = 1 }
    \$1 == \"ext\" && \$2 == 131072  { if (\$0 !~ /shared/) bad = 1; seen1 = 1 }
    END { exit (bad > 0 || !seen0 || !seen1) }'"

# The destination agrees, and so does the source once synced: the
# answer must not depend on when or in what order it was asked.
log_must fiemap_has_flag shared $DST
log_must sync_pool $TESTPOOL
log_must fiemap_has_flag shared $SRC
log_must fiemap_has_flag shared $DST

log_pass $claim
