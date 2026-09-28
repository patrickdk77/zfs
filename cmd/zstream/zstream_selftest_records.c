// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Self-tests for the DRR_CLONE validator shared with the kernel
 * receive path, and for DRR_CLONE byteswapping.
 */

#include <err.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/byteorder.h>
#include <sys/dmu_recv.h>
#include <sys/dnode.h>
#include <sys/spa.h>
#include <sys/zfs_ioctl.h>
#include "zstream_byteswap.h"
#include "zstream_selftest.h"

static void
good_clone(struct drr_clone *c)
{
	memset(c, 0, sizeof (*c));
	c->drr_object = 5;
	c->drr_offset = 0x40000;
	c->drr_length = 0x20000;
	c->drr_toguid = 0x1111;
	c->drr_refguid = 0x2222;
	c->drr_refobject = 4;
	c->drr_refoffset = 0x20000;
}

static void
expect_ok(const struct drr_clone *c, const char *what)
{
	char errbuf[RECV_CHECK_ERRBUFLEN] = "";
	int err = recv_check_drr_clone(c, errbuf, sizeof (errbuf));

	if (err != 0) {
		errx(1, "%s: rejected with %d: %s", what, err,
		    errbuf);
	}
	if (errbuf[0] != '\0') {
		errx(1, "%s: accepted but errbuf set: %s", what,
		    errbuf);
	}
}

static void
expect_einval(const struct drr_clone *c, const char *what)
{
	char errbuf[RECV_CHECK_ERRBUFLEN] = "";
	int err = recv_check_drr_clone(c, errbuf, sizeof (errbuf));

	if (err == 0)
		errx(1, "%s: accepted, expected EINVAL", what);
	if (err != EINVAL)
		errx(1, "%s: got %d, expected EINVAL", what, err);
	if (errbuf[0] == '\0')
		errx(1, "%s: rejected without a message", what);
	if (recv_check_drr_clone(c, NULL, 0) != EINVAL)
		errx(1, "%s: NULL errbuf changed the verdict", what);
}

static void
clone_check_accepts(void)
{
	struct drr_clone c;

	good_clone(&c);
	expect_ok(&c, "typical record");

	good_clone(&c);
	c.drr_length = SPA_MINBLOCKSIZE;
	c.drr_offset = SPA_MINBLOCKSIZE * 3;
	c.drr_refoffset = 0;
	expect_ok(&c, "minimum block");

	good_clone(&c);
	c.drr_length = SPA_MAXBLOCKSIZE;
	c.drr_offset = SPA_MAXBLOCKSIZE;
	c.drr_refoffset = SPA_MAXBLOCKSIZE * 7;
	expect_ok(&c, "maximum block");

	good_clone(&c);
	c.drr_refguid = c.drr_toguid;
	c.drr_refobject = c.drr_object;
	c.drr_refoffset = 0;
	expect_ok(&c, "reference into the same object");

	good_clone(&c);
	c.drr_object = DN_MAX_OBJECT - 1;
	c.drr_refobject = DN_MAX_OBJECT - 1;
	expect_ok(&c, "highest object numbers");

	good_clone(&c);
	c.drr_length = 3 * SPA_MINBLOCKSIZE;
	c.drr_offset = 0;
	c.drr_refoffset = 0;
	expect_ok(&c, "single block of an odd size");
}

static void
clone_check_rejects(void)
{
	struct drr_clone c;

	good_clone(&c);
	c.drr_object = 0;
	expect_einval(&c, "object 0");

	good_clone(&c);
	c.drr_object = DN_MAX_OBJECT;
	expect_einval(&c, "object at DN_MAX_OBJECT");

	good_clone(&c);
	c.drr_refobject = 0;
	expect_einval(&c, "refobject 0");

	good_clone(&c);
	c.drr_refobject = DN_MAX_OBJECT;
	expect_einval(&c, "refobject at DN_MAX_OBJECT");

	good_clone(&c);
	c.drr_length = 0;
	expect_einval(&c, "length 0");

	good_clone(&c);
	c.drr_length = SPA_MINBLOCKSIZE / 2;
	c.drr_offset = 0;
	c.drr_refoffset = 0;
	expect_einval(&c, "length below SPA_MINBLOCKSIZE");

	good_clone(&c);
	c.drr_length = SPA_MAXBLOCKSIZE * 2;
	c.drr_offset = 0;
	c.drr_refoffset = 0;
	expect_einval(&c, "length above SPA_MAXBLOCKSIZE");

	good_clone(&c);
	c.drr_length = 0x30000;
	c.drr_offset = 0x60000;
	c.drr_refoffset = 0;
	expect_einval(&c, "odd-sized block past offset 0");

	good_clone(&c);
	c.drr_length = 0x30000;
	c.drr_offset = 0;
	c.drr_refoffset = 0x30000;
	expect_einval(&c, "odd-sized reference past offset 0");

	good_clone(&c);
	c.drr_length = 3000;
	c.drr_offset = 0;
	c.drr_refoffset = 0;
	expect_einval(&c, "length not a multiple of 512");

	good_clone(&c);
	c.drr_offset = 0x40000 + 512;
	expect_einval(&c, "offset not aligned to length");

	good_clone(&c);
	c.drr_refoffset = 0x20000 + 512;
	expect_einval(&c, "refoffset not aligned to length");

	good_clone(&c);
	c.drr_offset = UINT64_MAX - c.drr_length + 1;
	expect_einval(&c, "offset plus length overflows");

	good_clone(&c);
	c.drr_refoffset = UINT64_MAX - c.drr_length + 1;
	expect_einval(&c, "refoffset plus length overflows");

	good_clone(&c);
	c.drr_refguid = 0;
	expect_einval(&c, "refguid 0");
}

static void
clone_byteswap(void)
{
	dmu_replay_record_t drr, orig;
	struct drr_clone *c = &drr.drr_u.drr_clone;
	const struct drr_clone *o = &orig.drr_u.drr_clone;

	memset(&drr, 0, sizeof (drr));
	drr.drr_type = DRR_CLONE;
	c->drr_object = 0x0102030405060708ULL;
	c->drr_offset = 0x1112131415161718ULL;
	c->drr_length = 0x2122232425262728ULL;
	c->drr_toguid = 0x3132333435363738ULL;
	c->drr_refguid = 0x4142434445464748ULL;
	c->drr_refobject = 0x5152535455565758ULL;
	c->drr_refoffset = 0x6162636465666768ULL;
	orig = drr;

	byteswap_record(&drr, DRR_CLONE);
	if (c->drr_object != BSWAP_64(o->drr_object) ||
	    c->drr_offset != BSWAP_64(o->drr_offset) ||
	    c->drr_length != BSWAP_64(o->drr_length) ||
	    c->drr_toguid != BSWAP_64(o->drr_toguid) ||
	    c->drr_refguid != BSWAP_64(o->drr_refguid) ||
	    c->drr_refobject != BSWAP_64(o->drr_refobject) ||
	    c->drr_refoffset != BSWAP_64(o->drr_refoffset))
		errx(1, "one swap did not reverse every field");

	byteswap_record(&drr, DRR_CLONE);
	if (memcmp(&drr.drr_u.drr_clone, &orig.drr_u.drr_clone,
	    sizeof (struct drr_clone)) != 0)
		errx(1, "two swaps did not restore the record");
}

static void
clone_record_layout(void)
{
	if (DRR_CLONE != DRR_REDACT + 1)
		errx(1, "DRR_CLONE is not the type after DRR_REDACT");
	if (DRR_CLONE + 1 != DRR_NUMTYPES)
		errx(1, "DRR_CLONE is not the last record type");
	if (sizeof (struct drr_clone) != 7 * sizeof (uint64_t)) {
		errx(1, "drr_clone is %zu bytes, expected %zu",
		    sizeof (struct drr_clone),
		    7 * sizeof (uint64_t));
	}
	if ((DMU_BACKUP_FEATURE_MASK &
	    DMU_BACKUP_FEATURE_CLONES) == 0)
		errx(1, "CLONES not in DMU_BACKUP_FEATURE_MASK");
	if (DMU_BACKUP_FEATURE_CLONES != (1 << 30))
		errx(1, "CLONES is not bit 30");
}

const test_case_t selftest_records_cases[] = {
	{ "clone_record_layout",	clone_record_layout },
	{ "clone_check_accepts",	clone_check_accepts },
	{ "clone_check_rejects",	clone_check_rejects },
	{ "clone_byteswap",		clone_byteswap },
	{ NULL,				NULL },
};
