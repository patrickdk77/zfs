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

. $STF_SUITE/tests/functional/zil_acl_mode/zil_acl_mode.kshlib

#
# DESCRIPTION:
#	Replay restores the post-umask mode of a new file and
#	directory.
#
# STRATEGY:
#	1. Create a pool with a ZIL header, once with acltype=posix
#	   and once with acltype=off.
#	2. Freeze the pool.
#	3. Create a file and a directory with umask 022, and sync.
#	4. Export and import the pool to replay the log.
#	5. Check that the modes are 644 and 755 before the replay and
#	   unchanged after it.
#
#	With acltype=posix ZFS applies the umask. With acltype=off the
#	VFS applies it.
#

verify_runnable "global"

claim="A create replayed from the log keeps its post-umask mode"

log_assert $claim
log_onexit zam_cleanup_pool

typeset -i fails=0
typeset oldmask=$(umask)

for acltype in posix off; do
	zam_cleanup_pool
	zam_setup_pool $acltype

	typeset base=/$TESTPOOL/$TESTFS
	log_must zpool freeze $TESTPOOL

	umask 022
	log_must touch $base/file
	log_must mkdir $base/dir
	umask $oldmask
	log_must sync $base/file $base/dir

	typeset fmode=$(zam_mode $base/file)
	typeset dmode=$(zam_mode $base/dir)
	log_note "acltype=$acltype before replay:" \
	    "file $fmode dir $dmode"

	#
	# Without the umask, the replay check proves nothing.
	#
	if [[ "$fmode" != "644" || "$dmode" != "755" ]]; then
		log_note "acltype=$acltype: umask 022 was not" \
		    "applied before the replay: file $fmode" \
		    "dir $dmode, wanted 644 and 755"
		((fails = fails + 1))
	fi

	zam_replay

	zam_check $base/file $fmode "acltype=$acltype" ||
	    ((fails = fails + 1))
	zam_check $base/dir $dmode "acltype=$acltype" ||
	    ((fails = fails + 1))
done

umask $oldmask
((fails != 0)) && log_fail "$fails mode checks failed, see above"

log_pass $claim
