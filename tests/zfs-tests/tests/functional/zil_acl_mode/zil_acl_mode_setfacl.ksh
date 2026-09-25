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
#	A mode changed by setfacl survives a log replay.
#
# STRATEGY:
#	1. Create an acltype=posix pool with two files, and sync.
#	2. Freeze the pool.
#	3. Run setfacl on each file. The first ACL is equivalent to a
#	   mode and stores no ACL. The second adds a named user entry,
#	   which stores an ACL and puts the group bits in the mask.
#	4. Export and import the pool to replay the log.
#	5. Check that both modes match the modes before the replay.
#

verify_runnable "global"

claim="A mode changed by setfacl survives a log replay"

log_assert $claim
log_onexit zam_cleanup_pool

typeset -i fails=0
typeset oldmask=$(umask)

zam_setup_pool posix

typeset base=/$TESTPOOL/$TESTFS

umask 022
log_must touch $base/equiv $base/named
umask $oldmask
sync_pool $TESTPOOL

typeset before_equiv=$(zam_mode $base/equiv)
typeset before_named=$(zam_mode $base/named)
log_note "before setfacl: equiv $before_equiv named $before_named"

log_must zpool freeze $TESTPOOL

log_must setfacl -m u::rwx,g::---,o::--- $base/equiv
log_must setfacl -m u:nobody:rwx $base/named
log_must sync $base/equiv $base/named

typeset emode=$(zam_mode $base/equiv)
typeset nmode=$(zam_mode $base/named)
log_note "after setfacl, before replay: equiv $emode named $nmode"

#
# The replay check proves nothing unless setfacl changed the modes.
#
if [[ "$emode" == "$before_equiv" ]]; then
	log_note "setfacl did not change the equivalent-mode file:" \
	    "still $emode"
	((fails = fails + 1))
fi
if [[ "$nmode" == "$before_named" ]]; then
	log_note "setfacl did not change the named-entry file:" \
	    "still $nmode"
	((fails = fails + 1))
fi

zam_replay

zam_check $base/equiv $emode "setfacl equivalent" ||
    ((fails = fails + 1))
zam_check $base/named $nmode "setfacl named" ||
    ((fails = fails + 1))

((fails != 0)) && log_fail "$fails mode checks failed, see above"

log_pass $claim
