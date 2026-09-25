#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#
. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/direct/dio.cfg
. $STF_SUITE/tests/functional/direct/dio.kshlib

#
# DESCRIPTION:
#	A Direct I/O write whose buffer changes in flight fails
#	checksum verify and is rewritten through the ARC.
#
# STRATEGY:
#	1. Turn on zfs_vdev_direct_write_verify and turn off
#	   compression, which copies the buffer before the checksum
#	   and so hides the change
#	2. Write a file with O_DIRECT while another thread changes the
#	   buffer
#	3. Every write must return its full length
#	4. Check that Direct I/O writes ran and some failed verify
#	5. Read the file back and check the pool for errors
#

verify_runnable "global"

if is_freebsd; then
	log_unsupported "FreeBSD has stable pages for O_DIRECT writes"
fi

log_assert "A Direct I/O write with a changing buffer completes"

typeset -i NUMBLOCKS=300
typeset -i BS
((BS = 128 * 1024))
typeset mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)
typeset f="$mntpnt/dio-fallback.iso"
typeset wr_verify=$(get_tunable VDEV_DIRECT_WR_VERIFY)
typeset wr_events=$(get_tunable DIO_WRITE_VERIFY_EVENTS_PER_SECOND)

function cleanup
{
	rm -f $f
	log_must zpool clear $TESTPOOL
	log_must zpool events -c
	log_must set_tunable32 VDEV_DIRECT_WR_VERIFY $wr_verify
	log_must set_tunable32 DIO_WRITE_VERIFY_EVENTS_PER_SECOND \
	    $wr_events
}
log_onexit cleanup

log_must set_tunable32 VDEV_DIRECT_WR_VERIFY 1
log_must set_tunable32 DIO_WRITE_VERIFY_EVENTS_PER_SECOND 1000000
log_must zfs set compression=off recordsize=128k $TESTPOOL/$TESTFS

log_must file_write -o create -f $f -b $BS -c $NUMBLOCKS -w

typeset -i before=$(kstat_pool $TESTPOOL iostats.direct_write_count)

#
# Without -e the helper exits 2 on a failed or short write.
#
log_must manipulate_user_buffer -f $f -n $NUMBLOCKS -b $BS -w

typeset -i after=$(kstat_pool $TESTPOOL iostats.direct_write_count)
if ((after <= before)); then
	log_fail "no Direct I/O writes were counted"
fi
check_dio_chksum_verify_failures $TESTPOOL "raidz" 1 "wr"

typeset -i filesize=$(get_file_size $f)
typeset -i num_blocks
((num_blocks = filesize / BS))
log_must stride_dd -i $f -o /dev/null -b $BS -c $num_blocks

log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A Direct I/O write with a changing buffer completes"
