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
# Description:
# A receive into an encrypted dataset leaves user accounting for
# later. Mounting and reading the received dataset must not write
# it, so the next incremental receive needs no -F. The accounting
# is built when the dataset is first written or when zfs userspace
# reads it.
#
# Strategy:
# 1. Create an encrypted dataset with 1000 files and snapshot it.
# 2. Receive it raw, and as a plain stream under an encrypted
#    parent, both with atime=off.
# 3. Mount both, read every file, run sync, and check written is
#    0.
# 4. Receive an incremental into each without -F.
# 5. Remount the raw copy. zfs userspace must list root, and the
#    accounting it builds must show up in written.
# 6. Remount the plain copy, write one file, and check that the
#    accounting is then built.
# 7. Open a new zvol, which has no snapshot of its own.
#

verify_runnable "both"

typeset passphrase="password1"
typeset src=$POOL/mu_src
typeset raw=$POOL/mu_raw
typeset encp=$POOL/mu_encp
typeset plain=$POOL/mu_encp/plain
typeset vol=$POOL/mu_vol

function cleanup
{
	for ds in $src $raw $encp $vol; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	rm -f $BACKDIR/mu.*
}

function wait_written_over # dataset bytes
{
	typeset -i n=0
	while ((n < 30)); do
		sync_pool $POOL
		(($(get_prop written $1) > $2)) && return 0
		sleep 1
		((n++))
	done
	return 1
}

log_assert "Mounting a dataset received into encryption does not" \
    "write it"
log_onexit cleanup

log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $src"
log_must eval "echo $passphrase | zfs create -o encryption=on" \
    "-o keyformat=passphrase $encp"
typeset -i i
for ((i = 1; i <= 1000; i++)); do
	echo $i > /$src/f$i
done
log_must zfs snapshot $src@a

log_must eval "zfs send -w $src@a | zfs recv -u -o atime=off $raw"
log_must eval "echo $passphrase | zfs load-key $raw"
log_must zfs mount $raw
log_must eval "zfs send $src@a | zfs recv -o atime=off $plain"

for ds in $raw $plain; do
	log_must eval "cat /$ds/f* >/dev/null"
done
log_must sync
sync_pool $POOL
sleep 2
sync_pool $POOL
for ds in $raw $plain; do
	log_note "$ds written after mount: $(get_prop written $ds)"
	log_must test "$(get_prop written $ds)" = "0"
done

for ((i = 1001; i <= 1010; i++)); do
	echo $i > /$src/f$i
done
log_must zfs snapshot $src@b
log_must eval "zfs send -w -i @a $src@b | zfs recv $raw"
log_must eval "zfs send -i @a $src@b | zfs recv $plain"
for ds in $raw $plain; do
	log_must cmp /$src/f1010 /$ds/f1010
done

log_must zfs unmount $raw
log_must zfs mount $raw
log_must test "$(get_prop written $raw)" = "0"
log_must eval "zfs userspace -Hp -o name,used $raw >$BACKDIR/mu.us"
typeset rootused=$(awk '$1 == "root" {print $2}' $BACKDIR/mu.us)
log_note "zfs userspace: root used $rootused"
log_must test -n "$rootused"
log_must test "$rootused" -gt 0
log_must wait_written_over $raw 500000

log_must zfs unmount $plain
log_must zfs mount $plain
log_must test "$(get_prop written $plain)" = "0"
log_must eval "echo new >/$plain/new"
log_must wait_written_over $plain 500000

log_must zfs create -V 16M $vol
block_device_wait $ZVOL_DEVDIR/$vol
log_must dd if=$ZVOL_DEVDIR/$vol of=/dev/null bs=64k count=1

log_pass "Mounting a dataset received into encryption does not" \
    "write it"
