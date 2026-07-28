// SPDX-License-Identifier: CDDL-1.0
/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * CDDL HEADER END
 */
/*
 * Copyright (c) 2026 by the OpenZFS project.
 *
 * Minimal scriptable FS_IOC_FIEMAP dumper for the ZTS fiemap tests.
 *
 * Prints one line per returned extent:
 *   ext <logical> <physical> <length> <flags_hex> [flag names...]
 * followed by a summary line:
 *   mapped <count>
 * On ioctl/open failure it prints, to stdout, and exits 1:
 *   error <errno> <strerror>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <getopt.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <linux/fiemap.h>

/* ZFS-specific request flags; keep in sync with include/sys/fiemap.h. */
#ifndef FIEMAP_FLAG_COPIES
#define	FIEMAP_FLAG_COPIES	0x08000000
#endif
#ifndef FIEMAP_FLAG_NOMERGE
#define	FIEMAP_FLAG_NOMERGE	0x04000000
#endif
#ifndef FIEMAP_FLAG_HOLES
#define	FIEMAP_FLAG_HOLES	0x02000000
#endif
#ifndef FIEMAP_EXTENT_SHARED
#define	FIEMAP_EXTENT_SHARED	0x00002000
#endif

typedef unsigned long long u_ll;

static void
print_flag_names(uint32_t f)
{
	struct { uint32_t bit; const char *name; } tbl[] = {
		{ FIEMAP_EXTENT_LAST,		"last" },
		{ FIEMAP_EXTENT_UNKNOWN,	"unknown" },
		{ FIEMAP_EXTENT_DELALLOC,	"delalloc" },
		{ FIEMAP_EXTENT_ENCODED,	"encoded" },
		{ FIEMAP_EXTENT_DATA_ENCRYPTED,	"encrypted" },
		{ FIEMAP_EXTENT_NOT_ALIGNED,	"not_aligned" },
		{ FIEMAP_EXTENT_DATA_INLINE,	"inline" },
		{ FIEMAP_EXTENT_UNWRITTEN,	"unwritten" },
		{ FIEMAP_EXTENT_MERGED,		"merged" },
		{ FIEMAP_EXTENT_SHARED,		"shared" },
	};

	for (size_t i = 0; i < sizeof (tbl) / sizeof (tbl[0]); i++) {
		if (f & tbl[i].bit)
			printf(" %s", tbl[i].name);
	}
}

static void
usage(void)
{
	fprintf(stderr, "usage: fiemap [-s start] [-l length] "
	    "[-c max_extents] [-S] [-C] [-N] [-H] <file>\n"
	    "  -s start        start offset (bytes, default 0)\n"
	    "  -l length       length (bytes, default whole file)\n"
	    "  -c max_extents  extent buffer size (0 = count only, "
	    "default 1024)\n"
	    "  -S              FIEMAP_FLAG_SYNC\n"
	    "  -C              FIEMAP_FLAG_COPIES (ZFS)\n"
	    "  -N              FIEMAP_FLAG_NOMERGE (ZFS)\n"
	    "  -H              FIEMAP_FLAG_HOLES (ZFS)\n");
}

int
main(int argc, char **argv)
{
	uint64_t start = 0, length = FIEMAP_MAX_OFFSET;
	uint32_t count = 1024;
	uint32_t flags = 0;
	int c;

	while ((c = getopt(argc, argv, "s:l:c:SCNH")) != -1) {
		switch (c) {
		case 's': start = strtoull(optarg, NULL, 0); break;
		case 'l': length = strtoull(optarg, NULL, 0); break;
		case 'c': count = strtoul(optarg, NULL, 0); break;
		case 'S': flags |= FIEMAP_FLAG_SYNC; break;
		case 'C': flags |= FIEMAP_FLAG_COPIES; break;
		case 'N': flags |= FIEMAP_FLAG_NOMERGE; break;
		case 'H': flags |= FIEMAP_FLAG_HOLES; break;
		default: usage(); return (2);
		}
	}

	if (optind >= argc) {
		usage();
		return (2);
	}

	/*
	 * O_NONBLOCK so that opening a FIFO or device special file does not
	 * block waiting for a peer; we only want to hand its fd to the ioctl.
	 */
	int fd = open(argv[optind], O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		printf("error %d %s\n", errno, strerror(errno));
		return (1);
	}

	size_t sz = sizeof (struct fiemap) +
	    (size_t)count * sizeof (struct fiemap_extent);
	struct fiemap *fm = calloc(1, sz);
	if (fm == NULL) {
		printf("error %d %s\n", ENOMEM, strerror(ENOMEM));
		return (1);
	}

	fm->fm_start = start;
	fm->fm_length = length;
	fm->fm_flags = flags;
	fm->fm_extent_count = count;

	if (ioctl(fd, FS_IOC_FIEMAP, fm) < 0) {
		printf("error %d %s\n", errno, strerror(errno));
		free(fm);
		close(fd);
		return (1);
	}

	/*
	 * In count-only mode (fm_extent_count == 0) the kernel fills no extent
	 * array, so only iterate the entries we actually provided room for.
	 */
	for (uint32_t i = 0; i < fm->fm_mapped_extents && i < count; i++) {
		struct fiemap_extent *e = &fm->fm_extents[i];
		printf("ext %llu %llu %llu 0x%x",
		    (u_ll)e->fe_logical, (u_ll)e->fe_physical,
		    (u_ll)e->fe_length, e->fe_flags);
		print_flag_names(e->fe_flags);
		printf("\n");
	}
	printf("mapped %u\n", fm->fm_mapped_extents);

	free(fm);
	close(fd);
	return (0);
}
