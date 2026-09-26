#!/usr/bin/env python3
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

"""Rewrite a native-order send stream for the send_clone_refs tests.

    noflag IN OUT    clear the clones feature flag
    selfref IN OUT   point the first DRR_CLONE at its own destination

Every record checksum after the change is recomputed, so the result
differs from a valid stream only in the field the test is about.
"""

import struct
import sys

RECORD_SIZE = 312
CKSUM_OFFSET = 280
DRR_BEGIN, DRR_OBJECT, DRR_WRITE, DRR_SPILL = 0, 1, 3, 7
DRR_WRITE_EMBEDDED, DRR_CLONE = 8, 11
FEATURE_CLONES = 1 << 30


def up8(n):
    return (n + 7) & ~7


def payload_len(data, off):
    rtype, plen = struct.unpack_from("=II", data, off)
    body = off + 8
    if rtype == DRR_BEGIN:
        return plen
    if rtype == DRR_OBJECT:
        return up8(struct.unpack_from("=I", data, body + 20)[0])
    if rtype == DRR_WRITE:
        lsize, = struct.unpack_from("=Q", data, body + 24)
        ctype = data[body + 42]
        csize, = struct.unpack_from("=Q", data, body + 88)
        return csize if ctype != 0 else lsize
    if rtype == DRR_SPILL:
        length, = struct.unpack_from("=Q", data, body + 8)
        ctype = data[body + 25]
        csize, = struct.unpack_from("=Q", data, body + 32)
        return csize if ctype != 0 else length
    if rtype == DRR_WRITE_EMBEDDED:
        return up8(struct.unpack_from("=I", data, body + 44)[0])
    return 0


def fletcher4(buf, state):
    a, b, c, d = state
    mask = (1 << 64) - 1
    for (word,) in struct.iter_unpack("=I", buf):
        a = (a + word) & mask
        b = (b + a) & mask
        c = (c + b) & mask
        d = (d + c) & mask
    return (a, b, c, d)


def rewrite(mode, data):
    state = (0, 0, 0, 0)
    off = 0
    done = False
    while off < len(data):
        rtype = struct.unpack_from("=I", data, off)[0]
        plen = payload_len(data, off)
        if rtype == DRR_BEGIN:
            state = (0, 0, 0, 0)
            if mode == "noflag":
                vi, = struct.unpack_from("=Q", data, off + 16)
                vi &= ~(FEATURE_CLONES << 2)
                struct.pack_into("=Q", data, off + 16, vi)
        elif rtype == DRR_CLONE and mode == "selfref" and not done:
            obj, dst, _len, toguid = struct.unpack_from(
                "=QQQQ", data, off + 8)
            struct.pack_into("=QQQ", data, off + 40, toguid, obj, dst)
            done = True
        state = fletcher4(data[off:off + CKSUM_OFFSET], state)
        if rtype != DRR_BEGIN:
            struct.pack_into("=4Q", data, off + CKSUM_OFFSET, *state)
        state = fletcher4(data[off + CKSUM_OFFSET:off + RECORD_SIZE],
                          state)
        state = fletcher4(
            data[off + RECORD_SIZE:off + RECORD_SIZE + plen], state)
        off += RECORD_SIZE + plen
    return done or mode == "noflag"


def main():
    mode, src, dst = sys.argv[1:4]
    data = bytearray(open(src, "rb").read())
    if not rewrite(mode, data):
        sys.exit("no DRR_CLONE record in " + src)
    open(dst, "wb").write(data)


if __name__ == "__main__":
    main()
