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
. $STF_SUITE/tests/functional/acl/acl_common.kshlib

#
# DESCRIPTION:
#	Setting a POSIX ACL clears setgid when the caller is not in
#	the file's group and lacks CAP_FSETID, as chmod does.
#
# STRATEGY:
#	1. Make a setgid file owned by an unprivileged user and a
#	   group that user is not in
#	2. Have that user set an access ACL, and verify setgid is
#	   clear
#	3. Repeat with the user's own group, and verify setgid is kept
#	4. Repeat as root with the first group, and verify setgid is
#	   kept
#

verify_runnable "both"

log_assert "setfacl by a non-group member clears setgid"

typeset f=$TESTDIR/sgid.file
typeset grp=sgidgrp
typeset mode

function cleanup
{
	rm -f $f
	del_group $grp 2>/dev/null
}
log_onexit cleanup

#
# Set an access ACL on a setgid file owned by $ZFS_ACL_STAFF1 and
# group $1, as $ZFS_ACL_STAFF1, or as root when $2 is "root".
#
function setfacl_on_setgid # group [root]
{
	log_must rm -f $f
	log_must touch $f
	log_must chown $ZFS_ACL_STAFF1:$1 $f
	log_must chmod 2755 $f
	mode=$(stat -c %a $f)
	if [[ "$mode" != 2755 ]]; then
		log_fail "could not create a setgid file: mode $mode"
	fi

	if [[ "$2" == root ]]; then
		log_must setfacl -m u:$ZFS_ACL_STAFF1:rw $f
	else
		log_must user_run $ZFS_ACL_STAFF1 \
		    "setfacl -m u:$ZFS_ACL_STAFF1:rw $f"
	fi
	mode=$(stat -c %a $f)
}

# $ZFS_ACL_STAFF1 is not a member of this group.
log_must add_group $grp

setfacl_on_setgid $grp
if [[ "$mode" == 2* ]]; then
	log_fail "setgid survived setfacl by a non-member: mode $mode"
fi

setfacl_on_setgid $ZFS_ACL_STAFF_GROUP
if [[ "$mode" != 2* ]]; then
	log_fail "setgid was cleared for a group member: mode $mode"
fi

setfacl_on_setgid $grp root
if [[ "$mode" != 2* ]]; then
	log_fail "setgid was cleared for root: mode $mode"
fi

log_pass "setfacl by a non-group member clears setgid"
