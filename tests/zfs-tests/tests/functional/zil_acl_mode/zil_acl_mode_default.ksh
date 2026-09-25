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
#	An object created under a default ACL keeps its inherited
#	mode across a log replay.
#
# STRATEGY:
#	1. Create an acltype=posix pool and give a directory in it a
#	   default ACL.
#	2. Freeze the pool.
#	3. Create a file and a directory inside it and sync them.
#	4. Export and import the pool to replay the log.
#	5. Check that the modes match the modes before the replay.
#

verify_runnable "global"

claim="A create under a default ACL keeps its mode across replay"

log_assert $claim
log_onexit zam_cleanup_pool

typeset -i fails=0
typeset oldmask=$(umask)

zam_setup_pool posix

typeset base=/$TESTPOOL/$TESTFS
typeset parent=$base/parent

log_must mkdir $parent
log_must setfacl -d -m u::rwx,g::r-x,o::--- $parent
sync_pool $TESTPOOL

log_must zpool freeze $TESTPOOL

umask 022
log_must mkdir $parent/dir
log_must touch $parent/file
umask $oldmask
log_must sync $parent/dir $parent/file

typeset dmode=$(zam_mode $parent/dir)
typeset fmode=$(zam_mode $parent/file)
log_note "before replay: dir $dmode file $fmode"

#
# The default ACL gives other no access. A 777 or 666 mode means
# the ACL was not inherited and the replay check proves nothing.
#
if [[ "$dmode" == "777" || "$fmode" == "666" ]]; then
	log_note "the default ACL was not applied before the" \
	    "replay: dir $dmode file $fmode"
	((fails = fails + 1))
fi

zam_replay

zam_check $parent/dir $dmode "default acl" || ((fails = fails + 1))
zam_check $parent/file $fmode "default acl" || ((fails = fails + 1))

((fails != 0)) && log_fail "$fails mode checks failed, see above"

log_pass $claim
