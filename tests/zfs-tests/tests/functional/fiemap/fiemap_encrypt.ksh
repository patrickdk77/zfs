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
#	FIEMAP flags extents on an encrypted dataset DATA_ENCRYPTED, and (per
#	the FIEMAP contract) also ENCODED.
#

verify_runnable "global"

claim="FIEMAP flags encrypted extents ENCRYPTED and ENCODED."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled -O recordsize=128k \
    $TESTPOOL $DISKS

typeset passphrase="fiemap-secret"
log_must eval "echo $passphrase | zfs create -o encryption=aes-256-gcm" \
    "-o keyformat=passphrase -o keylocation=prompt $TESTPOOL/enc"

log_must dd if=/dev/urandom of=/$TESTPOOL/enc/e bs=128k count=4
log_must sync_pool $TESTPOOL

log_must fiemap_all_flag encrypted /$TESTPOOL/enc/e
log_must fiemap_all_flag encoded /$TESTPOOL/enc/e

log_pass $claim
