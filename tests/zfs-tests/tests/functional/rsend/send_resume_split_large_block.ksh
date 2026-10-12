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
# A send without -L splits each 1M block into 128K WRITE records.
# A receive cut off partway through such a block saves a resume
# offset inside the block. The resumed send must start at that
# offset, and the received files must match the source.
#
# Strategy:
# 1. Write a 6M file and a file with one 293K block, which ends
#    in a short chunk, to a recordsize=1m dataset.
# 2. Send the snapshot without -L, plain and with -c.
# 3. Cut each stream at five points, the last two near the end
#    of the stream, and receive with -s.
# 4. Resume with zfs send -t. The first WRITE for the resume
#    object must be at the saved offset.
# 5. Finish the receive and compare the files.
# 6. At least one saved offset must fall inside a block.
#

verify_runnable "both"

typeset BLK=1048576
typeset sendfs=$POOL/fs
typeset recvfs=$POOL/recv
typeset full=$BACKDIR/stream.full
typeset rest=$BACKDIR/stream.rest

function cleanup
{
	rm -f $BACKDIR/stream.*
	for ds in $sendfs $recvfs; do
		datasetexists $ds && destroy_dataset $ds -r
	done
}

function token_val # token name
{
	zstream token $1 | awk -v n="$2:" '$1 == n {print $2}'
}

function first_write_off # stream object
{
	zstream dump -v $1 | awk -v o=$2 '$1 == "WRITE" && $4 == o {
		for (i = 1; i < NF; i++)
			if ($i == "offset") {
				print $(i + 2)
				exit
			}
	}'
}

log_assert "A resumed send of split large blocks starts at the" \
    "saved offset"
log_onexit cleanup

log_must zfs create -o recordsize=1m $sendfs
log_must dd if=/dev/urandom of=/$sendfs/big bs=1024k count=6
log_must dd if=/dev/urandom of=/$sendfs/tail bs=1000 count=300
log_must zfs snapshot $sendfs@snap

typeset -i inside=0
for flags in "" "-c"; do
	log_must eval "zfs send $flags $sendfs@snap >$full"
	typeset -i size=$(stat_size $full)
	for cut in $((size * 2 / 9)) $((size * 4 / 9)) \
	    $((size * 6 / 9)) $((size - 100000)) $((size - 15000)); do
		log_mustnot eval "head -c $cut $full |" \
		    "zfs recv -s $recvfs"
		typeset tok=$(get_prop receive_resume_token $recvfs)
		log_must test "$tok" != "-"
		typeset obj=$(token_val $tok object)
		typeset off=$(token_val $tok offset)
		log_must test -n "$off"
		log_note "send $flags cut $cut: obj $obj off $off"
		((off % BLK != 0)) && ((inside++))

		log_must eval "zfs send -t $tok >$rest"
		typeset first=$(first_write_off $rest $obj)
		log_must test "$first" = "$off"

		log_must eval "zfs recv -s $recvfs <$rest"
		log_must diff /$sendfs/big /$recvfs/big
		log_must diff /$sendfs/tail /$recvfs/tail
		log_must_busy zfs destroy -r $recvfs
	done
done

log_note "$inside resume offsets fell inside a block"
log_must test $inside -ge 1

log_pass "A resumed send of split large blocks starts at the" \
    "saved offset"
