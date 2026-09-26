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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# DESCRIPTION:
# -k is refused together with -S, the saved partial send, since a
# partially received dataset holds no complete reference targets.
#
# STRATEGY:
# 1. Leave a partially received dataset behind with zfs recv -s.
# 2. zfs send -S on it works, so the dataset is a real saved send.
# 3. zfs send -S -k on it fails with the incompatible-flags error.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cv -r
	destroy_dataset $POOL2/cv -r
	rm -f $BACKDIR/cv-full $BACKDIR/cv-saved
}

log_assert "zfs send -S -k is refused on a partially received dataset"
log_onexit cleanup

typeset src=$POOL/cv
typeset dst=$POOL2/cv

log_must zfs create $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/f1 bs=128k count=64
log_must zfs snapshot $src@s
log_must eval "zfs send $src@s > $BACKDIR/cv-full"
typeset size=$(stat_size $BACKDIR/cv-full)
log_must truncate -s $((size / 2)) $BACKDIR/cv-full
log_mustnot eval "zfs recv -s $dst < $BACKDIR/cv-full"
log_must [ "$(get_prop receive_resume_token $dst)" != "-" ]

log_must eval "zfs send -S $dst > $BACKDIR/cv-saved"
log_mustnot eval "zfs send -S -k $dst > /dev/null"
log_must eval "zfs send -S -k $dst 2>&1 >/dev/null | \
    grep -q 'incompatible flags'"

log_pass "zfs send -S -k is refused on a partially received dataset"
