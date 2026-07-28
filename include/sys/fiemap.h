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
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */
/*
 * Copyright (c) 2018, Lawrence Livermore National Security, LLC.
 *
 * FIEMAP support, backported from the (unmerged) upstream PR #7545 to the
 * 2.4.x branch.  This variant walks only the synced on-disk block tree: the
 * caller forces a txg sync before assembly, so the pending dirty/free
 * range-tree machinery from the original patch is not needed here.
 */

#ifndef	_SYS_FIEMAP_H
#define	_SYS_FIEMAP_H

/*
 * FIEMAP interface flags.  These ZFS-specific flags were proposed but never
 * landed in the Linux kernel, so they are treated as a ZFS extension and are
 * masked out of the generic compatibility check.
 */
/*
 * Request that all copies of an extent be reported.  They are reported as
 * overlapping logical extents with different physical extents.
 */
#ifndef FIEMAP_FLAG_COPIES
#define	FIEMAP_FLAG_COPIES	0x08000000
#endif

/*
 * Request that each block be reported and not merged into an extent.
 */
#ifndef FIEMAP_FLAG_NOMERGE
#define	FIEMAP_FLAG_NOMERGE	0x04000000
#endif

/*
 * Request that holes be reported as FIEMAP_EXTENT_UNWRITTEN extents.
 */
#ifndef FIEMAP_FLAG_HOLES
#define	FIEMAP_FLAG_HOLES	0x02000000
#endif

#ifndef FIEMAP_EXTENT_SHARED
#define	FIEMAP_EXTENT_SHARED	0x00002000
#endif

#ifdef _KERNEL

#include <sys/spa.h>		/* for SPA_DVAS_PER_BP */
#include <sys/avl.h>

/*
 * Generic supported flags.  FIEMAP_FLAG_COPIES, FIEMAP_FLAG_NOMERGE, and
 * FIEMAP_FLAG_HOLES are excluded from the compatibility check since they are
 * a ZFS-specific extension.
 */
#define	ZFS_FIEMAP_FLAGS_COMPAT	(FIEMAP_FLAG_SYNC)
#define	ZFS_FIEMAP_FLAGS_ZFS	(FIEMAP_FLAG_COPIES | FIEMAP_FLAG_NOMERGE | \
				FIEMAP_FLAG_HOLES)

typedef struct zfs_fiemap_entry {
	uint64_t fe_logical_start;
	uint64_t fe_logical_len;
	uint64_t fe_physical_start;
	uint64_t fe_physical_len;
	uint64_t fe_vdev;
	uint64_t fe_flags;
	avl_node_t fe_node;
} zfs_fiemap_entry_t;

typedef struct zfs_fiemap {
	avl_tree_t fm_extent_trees[SPA_DVAS_PER_BP];	/* extent trees */

	uint64_t fm_file_size;		/* cached inode size */
	uint64_t fm_block_size;		/* cached dnp block size */
	uint64_t fm_vdev_bits;		/* vdev id width in fe_physical */
	boolean_t fm_full;		/* assembled fm_extents_max extents */
	uint64_t fm_reportable;		/* extents the fill would emit */

	/* Immutable */
	uint64_t fm_start;		/* start of requested range */
	uint64_t fm_length;		/* length of requested range */
	uint64_t fm_flags;		/* copy of fei.fi_flags */
	uint64_t fm_extents_max;	/* copy of fei.fi_extents_max */
	int fm_copies;
} zfs_fiemap_t;

struct fiemap_extent_info;

extern zfs_fiemap_t *zfs_fiemap_create(uint64_t start, uint64_t len,
    uint64_t flags, uint64_t max);
extern void zfs_fiemap_destroy(zfs_fiemap_t *fm);
extern int zfs_fiemap_assemble(struct inode *ip, zfs_fiemap_t *fm);
extern int zfs_fiemap_fill(zfs_fiemap_t *fm, struct fiemap_extent_info *fei,
    uint64_t start, uint64_t length);

#endif /* _KERNEL */
#endif	/* _SYS_FIEMAP_H */
