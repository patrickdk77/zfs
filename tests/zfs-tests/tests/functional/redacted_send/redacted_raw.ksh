#!/bin/ksh
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

. $STF_SUITE/tests/functional/redacted_send/redacted.kshlib

#
# Description:
# A raw incremental send from a redaction bookmark of an encrypted
# dataset must not need the key, as every other raw send does.
#
# Strategy:
# 1. Create an encrypted dataset with a file two levels deep and a
#    sparse file three levels deep. Redact its snapshot with respect
#    to a clone that changes both files, then write a new file and
#    take a second snapshot.
# 2. Send the first snapshot raw to the second pool as the base.
# 3. Export the pool and import it without loading the key, so the
#    ARC holds nothing decrypted.
# 4. Send a raw incremental from the redaction bookmark and receive
#    it. Both must succeed, and the received snapshot must have the
#    sender's guid.
#

verify_runnable "both"

typeset ds_name="raw"
typeset sendfs="$POOL/$ds_name"
typeset clone="$POOL/${ds_name}_clone"
typeset recvfs="$POOL2/$ds_name"
typeset stream=$(mktemp $TEST_BASE_DIR/redacted_raw.XXXX)
typeset keyfile=$(mktemp $TEST_BASE_DIR/redacted_raw_key.XXXX)

function cleanup
{
	poolexists $POOL || zpool import $POOL
	datasetexists $sendfs && destroy_dataset $sendfs -R
	zfs mount -a
	redacted_cleanup $recvfs
	rm -f $stream $keyfile
}

log_onexit cleanup

log_must eval "echo password > $keyfile"
log_must zfs create -o encryption=on -o keyformat=passphrase \
    -o keylocation=file://$keyfile $sendfs
typeset send_mnt="$(get_prop mountpoint $sendfs)"
log_must dd if=/dev/urandom of=$send_mnt/f1 bs=128k count=32
log_must dd if=/dev/urandom of=$send_mnt/f2 bs=128k count=2 seek=2000
log_must zfs snapshot $sendfs@snap0
log_must zfs clone $sendfs@snap0 $clone
typeset clone_mnt="$(get_prop mountpoint $clone)"
log_must dd if=/dev/urandom of=$clone_mnt/f1 bs=128k count=8 \
    conv=notrunc
log_must dd if=/dev/urandom of=$clone_mnt/f2 bs=128k count=1 \
    seek=2000 conv=notrunc
log_must zfs snapshot $clone@snap
log_must zfs redact $sendfs@snap0 book $clone@snap
log_must dd if=/dev/urandom of=$send_mnt/f3 bs=128k count=16
log_must zfs snapshot $sendfs@snap1

log_must eval "zfs send -w $sendfs@snap0 >$stream"
log_must eval "zfs receive -u $recvfs <$stream"

log_must zpool export $POOL
log_must zpool import -N $POOL
log_must test "$(get_prop keystatus $sendfs)" = "unavailable"

log_must eval "zfs send -w -i $sendfs#book $sendfs@snap1 >$stream"
log_must eval "zfs receive -u $recvfs <$stream"
log_must test "$(get_prop guid $recvfs@snap1)" = \
    "$(get_prop guid $sendfs@snap1)"

log_pass "A raw incremental from a redaction bookmark needs no key"
