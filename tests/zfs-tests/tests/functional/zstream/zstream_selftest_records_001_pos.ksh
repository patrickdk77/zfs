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

#
# DESCRIPTION:
# The zstream self-tests for stream records (the DRR_CLONE validator
# and its byteswap) all pass.
#

verify_runnable "both"

log_assert "zstream self-tests for stream records all pass"

log_must zstream selftest records

log_pass "zstream self-tests for stream records all pass"
