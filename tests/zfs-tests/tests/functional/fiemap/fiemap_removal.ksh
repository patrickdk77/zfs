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
#	After a device removal FIEMAP must not report an offset into the
#	indirect vdev as though it were a physical address.
#
# STRATEGY:
#	Removing a device leaves an indirect vdev behind, and block
#	pointers that still name it are remapped when read.  A split
#	block cannot be remapped to a single location, so its DVA keeps
#	naming the indirect vdev, and that offset addresses nothing on
#	any real device.  Such an extent has to be reported as unknown,
#	the way a gang block is, rather than as a physical range.
#
#	Write across two devices, remove one, and check that every
#	extent either carries a physical address that is not flagged
#	unknown, or is flagged unknown with no address at all.
#

verify_runnable "global"

claim="FIEMAP does not report indirect vdev offsets as physical."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

set -A d $DISKS
if [[ ${#d[@]} -lt 2 ]]; then
	log_unsupported "Needs at least two disks"
fi

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL ${d[0]} ${d[1]}

# Spread data over both devices before removing one, so the
# removal has something to remap.
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=1M count=64
log_must sync_pool $TESTPOOL

if ! zpool remove $TESTPOOL ${d[1]} 2>/dev/null; then
	log_unsupported "Pool layout does not support device removal"
fi

# Removal is asynchronous; wait for it to finish before mapping.
log_must zpool wait -t remove $TESTPOOL
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_mapped /$TESTPOOL/f)" -ge 1

# An extent flagged unknown must not also present an address, and the
# reverse: nothing may carry an address it cannot stand behind.
log_must eval "fiemap /$TESTPOOL/f | awk '
    \$1 == \"ext\" {
	    unknown = (\$0 ~ /unknown/)
	    if (unknown && \$3 != 0) { bad++ }
    }
    END { exit (bad > 0) }'"

log_must zpool status -x $TESTPOOL
log_pass $claim
