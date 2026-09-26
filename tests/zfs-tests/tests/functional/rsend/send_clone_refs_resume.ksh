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
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# DESCRIPTION:
# A send started with -k and interrupted resumes correctly, and the
# resumed stream carries no CLONE records.
#
# STRATEGY:
# 1. Write a file, clone it several times, snapshot.
# 2. Send with -k to a file and truncate the stream.
# 3. Receive with -s; it fails and leaves a resume token.
# 4. zfs send -k -t token: no clones feature, no CLONE records.
# 5. Receive the rest; contents match and zdb -b is clean.
#

verify_runnable "both"

function cleanup
{
	destroy_dataset $POOL/cs -r
	destroy_dataset $POOL2/cs -r
	rm -f $BACKDIR/cs-full $BACKDIR/cs-rest
}

log_assert "a resumed -k send receives and carries no CLONE records"
log_onexit cleanup

typeset src=$POOL/cs
typeset dst=$POOL2/cs

log_must zfs create -o recordsize=128k $src
typeset mnt=$(get_prop mountpoint $src)
log_must dd if=/dev/urandom of=$mnt/file1 bs=128k count=32
log_must sync_pool $POOL
for i in 2 3 4 5 6 7 8; do
	log_must clonefile -f $mnt/file1 $mnt/file$i
done
log_must sync_pool $POOL
log_must zfs snapshot $src@s

log_must eval "zfs send -k $src@s > $BACKDIR/cs-full"
log_must stream_has_features $BACKDIR/cs-full clones
typeset size=$(stat_size $BACKDIR/cs-full)
log_must truncate -s $((size / 2)) $BACKDIR/cs-full
log_mustnot eval "zfs recv -s $dst < $BACKDIR/cs-full"

typeset token=$(get_prop receive_resume_token $dst)
log_must [ "$token" != "-" ]
log_must eval "zfs send -k -t $token > $BACKDIR/cs-rest"
log_mustnot stream_has_features $BACKDIR/cs-rest clones
log_must [ "$(stream_clone_records $BACKDIR/cs-rest)" = "0" ]

log_must eval "zfs recv -s $dst < $BACKDIR/cs-rest"
typeset dmnt=$(get_prop mountpoint $dst)
for i in 1 2 3 4 5 6 7 8; do
	log_must have_same_content $mnt/file$i $dmnt/file$i
done
log_must zdb -b $POOL2

log_pass "a resumed -k send receives and carries no CLONE records"
