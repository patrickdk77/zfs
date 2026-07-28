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
 * FIEMAP support, backported from the unmerged upstream PR #7545.
 *
 * This is the Linux VFS side of the FIEMAP implementation.  It walks
 * only the synced on-disk block tree: zfs_fiemap_assemble() syncs a
 * dirty dnode under the file's range lock before walking, so the
 * pending dirty and free range-tree machinery from the original patch
 * is not needed and has been omitted.  A file with nothing
 * outstanding is already described by the synced tree, and is not
 * synced again.
 *
 * A DVA names a vdev as well as an offset, so an offset alone does
 * not identify a block on a multi-vdev pool.  The vdev id is folded
 * into the upper bits of fe_physical rather than in a reserved field
 * as the original patch did, which keeps the standard
 * fiemap_fill_next_extent() helper usable.  The field is only as wide
 * as the pool's top-level vdev count needs, so a pool with one
 * top-level vdev reports raw offsets; zfs_fiemap_tree_fill()
 * documents what the folding costs.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/kmem.h>
#include <sys/dmu.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_traverse.h>
#include <sys/dnode.h>
#include <sys/spa.h>
#include <sys/spa_impl.h>
#include <sys/zfeature.h>
#include <sys/vdev.h>
#include <sys/vdev_impl.h>
#include <sys/brt.h>
#include <sys/txg.h>
#include <sys/arc.h>
#include <sys/zio.h>
#include <sys/avl.h>
#include <sys/zfs_znode.h>
#include <sys/zfs_vnops.h>
#include <sys/zfs_rlock.h>
#include <sys/fiemap.h>
#include <linux/fiemap.h>

/*
 * Count an extent just added to the first tree if the fill would emit
 * it.  Holes are only emitted when FIEMAP_FLAG_HOLES was requested, so
 * counting tree nodes instead would stop the walk early and hand the
 * caller fewer extents than its array holds.
 */
static void
zfs_fiemap_count_reportable(zfs_fiemap_t *fm, uint64_t flags)
{
	if (!(flags & FIEMAP_EXTENT_UNWRITTEN) ||
	    (fm->fm_flags & FIEMAP_FLAG_HOLES))
		fm->fm_reportable++;
}

/*
 * Stop assembling once the first tree holds one extent more than
 * the caller's array; the fill would stop there anyway, so
 * anything further is a tree whose size is bounded only by the
 * file.  The extra extent proves the one before it is complete:
 * had the next block continued it, it would have merged rather
 * than start a new extent.  An fi_extents_max of zero is a count
 * request, which has no array and must see the whole range.
 */
static void
zfs_fiemap_check_full(zfs_fiemap_t *fm)
{
	if (fm->fm_extents_max != 0 &&
	    fm->fm_reportable > fm->fm_extents_max)
		fm->fm_full = B_TRUE;
}

/*
 * Insert an assembled extent, refusing to quietly produce a malformed
 * map.  Two extents may not start at the same offset, and one may not
 * begin inside the one before it: the walk visits each level 0 block
 * once, so either means the assembly is wrong.  The tree is keyed on
 * the start offset alone and so cannot see the second case by itself.
 *
 * A silent drop here is how an indirect-level hole recorded at the
 * wrong offset went unnoticed: it collided with a real entry, was
 * discarded, and the range it covered simply vanished from the map
 * with every test still passing.  Assert in a debug build, and in a
 * production one keep the entry already held rather than fail a
 * read-only ioctl.
 */
static void
zfs_fiemap_insert(zfs_fiemap_t *fm, int idx, zfs_fiemap_entry_t *fe)
{
	avl_tree_t *t = &fm->fm_extent_trees[idx];
	zfs_fiemap_entry_t *prev;
	avl_index_t where;

	if (avl_find(t, fe, &where) != NULL) {
		ASSERT(!"fiemap: two extents at the same offset");
		kmem_free(fe, sizeof (zfs_fiemap_entry_t));
		return;
	}

	prev = avl_nearest(t, where, AVL_BEFORE);
	if (prev != NULL) {
		uint64_t pend = prev->fe_logical_start +
		    prev->fe_logical_len;

		if (pend > fe->fe_logical_start) {
			ASSERT(!"fiemap: overlapping extents");
			kmem_free(fe, sizeof (zfs_fiemap_entry_t));
			return;
		}
	}

	avl_insert(t, fe, where);
	if (idx == 0)
		zfs_fiemap_count_reportable(fm, fe->fe_flags);
}

/*
 * Record a run of nblks unwritten level-zero blocks starting at block
 * first, used for a hole that occupies a whole indirect subtree.  Holes
 * live in the first tree only.
 */
static void
zfs_fiemap_add_hole_span(zfs_fiemap_t *fm, uint64_t first, uint64_t nblks)
{
	uint64_t blksz = fm->fm_block_size;
	uint64_t nr = (fm->fm_flags & FIEMAP_FLAG_NOMERGE) ? nblks : 1;
	uint64_t each = (fm->fm_flags & FIEMAP_FLAG_NOMERGE) ? 1 : nblks;

	for (uint64_t i = 0; i < nr; i++) {
		zfs_fiemap_entry_t *fe;

		fe = kmem_zalloc(sizeof (zfs_fiemap_entry_t), KM_SLEEP);
		fe->fe_logical_start = (first + i * each) * blksz;
		fe->fe_logical_len = each * blksz;
		fe->fe_flags = FIEMAP_EXTENT_UNWRITTEN;
		if (each > 1)
			fe->fe_flags |= FIEMAP_EXTENT_MERGED;

		zfs_fiemap_insert(fm, 0, fe);
	}

	zfs_fiemap_check_full(fm);
}

/*
 * Convert the provided level-zero block pointer into an extent.  This may
 * create a new extent or extend the previous adjacent one.
 */
static int
zfs_fiemap_cb(spa_t *spa, zilog_t *zilog, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp, void *arg)
{
	(void) zilog;
	zfs_fiemap_t *fm = (zfs_fiemap_t *)arg;

	/*
	 * Take the level from the bookmark, not from the block pointer.  A
	 * hole is an all-zero block pointer, so BP_GET_LEVEL() reads 0 for
	 * a hole at any level, and an indirect-level hole would be taken
	 * for a level 0 block and recorded at zb_blkid * block_size, an
	 * offset in the wrong units.  That offset usually collides with a
	 * real entry and is dropped by the tree insert below, so the range
	 * the hole actually covers goes unreported.
	 */
	if (zb->zb_level != 0) {
		/*
		 * A hole at an indirect level stands for every level 0
		 * block beneath it, and there are no block pointers below
		 * it to visit.  Report the whole span as one unwritten
		 * extent, in the first tree only, as holes elsewhere are.
		 * Anything else at level > 0 is interior tree structure
		 * with nothing to report.
		 */
		if (BP_IS_HOLE(bp) && dnp != NULL) {
			uint64_t span = bp_span_in_blocks(dnp->dn_indblkshift,
			    zb->zb_level);
			uint64_t first = zb->zb_blkid * span;
			uint64_t nblks = MIN(span,
			    dnp->dn_maxblkid + 1 - first);

			if (first <= dnp->dn_maxblkid && nblks > 0) {
				zfs_fiemap_add_hole_span(fm, first, nblks);
			}
		}
		return (0);
	}

	/*
	 * Remap indirect vdev block pointers to their real physical
	 * location.  Only a pool that has removed a vdev has anything
	 * to remap, so skip the block-pointer copy, the config lock,
	 * and the remap entirely otherwise.  This runs for every block
	 * pointer in the file.  The remapping is transparent so no
	 * additional flags are set.
	 */
	blkptr_t bp_copy;
	boolean_t indirect = B_FALSE;
	if (spa_feature_is_active(spa, SPA_FEATURE_DEVICE_REMOVAL)) {
		bp_copy = *bp;
		spa_config_enter(spa, SCL_VDEV, FTAG, RW_READER);
		if (spa_remap_blkptr(spa, &bp_copy, NULL, NULL))
			bp = &bp_copy;

		/*
		 * A split block cannot be remapped to one location,
		 * so the DVA may still name the indirect vdev left
		 * behind by a device removal.  That offset addresses
		 * nothing on any real device, so report the extent
		 * as unknown rather than hand back a number that
		 * looks physical.
		 */
		for (int d = 0; d < BP_GET_NDVAS(bp); d++) {
			uint64_t v = DVA_GET_VDEV(&bp->blk_dva[d]);
			vdev_t *vd = vdev_lookup_top(spa, v);

			if (vd != NULL &&
			    vd->vdev_ops == &vdev_indirect_ops) {
				indirect = B_TRUE;
				break;
			}
		}
		spa_config_exit(spa, SCL_VDEV, FTAG);
	}

	for (int i = 0; i < fm->fm_copies; i++) {
		zfs_fiemap_entry_t *fe, *pfe;

		/*
		 * Holes and embedded block pointers are only added to the
		 * first tree; the additional trees hold redundant copies.
		 */
		if (i > 0 && (BP_IS_HOLE(bp) || BP_IS_EMBEDDED(bp)))
			continue;

		fe = kmem_zalloc(sizeof (zfs_fiemap_entry_t), KM_SLEEP);
		fe->fe_logical_start = zb->zb_blkid * fm->fm_block_size;

		if (BP_IS_HOLE(bp)) {
			fe->fe_logical_len = fm->fm_block_size;
			fe->fe_flags |= FIEMAP_EXTENT_UNWRITTEN;
		} else if (BP_IS_EMBEDDED(bp)) {
			fe->fe_logical_len = BPE_GET_LSIZE(bp);
			fe->fe_physical_start = 0;
			fe->fe_physical_len = BPE_GET_PSIZE(bp);
			fe->fe_flags |= FIEMAP_EXTENT_DATA_INLINE |
			    FIEMAP_EXTENT_NOT_ALIGNED;

			if (BP_IS_ENCRYPTED(bp))
				fe->fe_flags |= FIEMAP_EXTENT_DATA_ENCRYPTED;
			if (BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF)
				fe->fe_flags |= FIEMAP_EXTENT_ENCODED;
		} else {
			if (i >= BP_GET_NDVAS(bp)) {
				kmem_free(fe, sizeof (zfs_fiemap_entry_t));
				continue;
			}

			if (BP_IS_ENCRYPTED(bp))
				fe->fe_flags |= FIEMAP_EXTENT_DATA_ENCRYPTED;
			if (BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF)
				fe->fe_flags |= FIEMAP_EXTENT_ENCODED;
			/*
			 * Mark shared blocks.  BP_GET_DEDUP covers
			 * the dedup table (DDT); the BRT covers
			 * block cloning, which postdates the
			 * original upstream patch.
			 * brt_maybe_exists() alone is only a
			 * per-vdev range filter and false-positives
			 * on any block near past clone activity, so
			 * confirm it with an exact lookup, which is
			 * only reached when the cheap filter says
			 * maybe.
			 *
			 * Both see only synced references, so a
			 * clone made in the still-open TXG is
			 * invisible to them.  Cloning out of a file
			 * does not dirty its dnode, so the sync
			 * above is not taken: mapping the source
			 * right after a clone reported it unshared
			 * while mapping the destination reported it
			 * shared.  One block, two answers, decided
			 * by which file was asked first.  Consult
			 * the pending references too, since the
			 * clone has already returned success.
			 * generic/353 and generic/702 cover this.
			 */
			if (BP_GET_DEDUP(bp) || (brt_maybe_exists(spa, bp) &&
			    brt_entry_get_refcount(spa, bp) > 0) ||
			    brt_pending_exists(spa, bp))
				fe->fe_flags |= FIEMAP_EXTENT_SHARED;

			/*
			 * Report gang blocks, and anything left on
			 * an indirect vdev, as one unknown extent.
			 */
			if (BP_IS_GANG(bp) || indirect) {
				fe->fe_flags |= FIEMAP_EXTENT_UNKNOWN;
				fe->fe_physical_start = 0;
				fe->fe_physical_len = 0;
				fe->fe_vdev = 0;
			} else {
				fe->fe_physical_len = BP_GET_PSIZE(bp);

				if (DVA_IS_VALID(&bp->blk_dva[i])) {
					fe->fe_vdev =
					    DVA_GET_VDEV(&bp->blk_dva[i]);
					fe->fe_physical_start =
					    DVA_GET_OFFSET(&bp->blk_dva[i]);
				}
			}

			fe->fe_logical_len = BP_GET_LSIZE(bp);
		}

		/*
		 * Merge compatible adjacent block pointers into a single
		 * extent.  Block pointers are visited in logical offset order
		 * so it is sufficient to check only the previous entry.
		 * Embedded block pointers are never merged.
		 */
		pfe = avl_last(&fm->fm_extent_trees[i]);
		if (pfe != NULL && !BP_IS_EMBEDDED(bp) &&
		    !(fm->fm_flags & FIEMAP_FLAG_NOMERGE)) {
			if (BP_IS_HOLE(bp) && fe->fe_flags ==
			    (pfe->fe_flags & ~FIEMAP_EXTENT_MERGED)) {
				pfe->fe_logical_len += fe->fe_logical_len;
				pfe->fe_flags |= FIEMAP_EXTENT_MERGED;
				kmem_free(fe, sizeof (zfs_fiemap_entry_t));
				continue;
			}

			if (!BP_IS_HOLE(bp) && fe->fe_flags ==
			    (pfe->fe_flags & ~FIEMAP_EXTENT_MERGED) &&
			    fe->fe_physical_start ==
			    pfe->fe_physical_start + pfe->fe_physical_len &&
			    fe->fe_vdev == pfe->fe_vdev) {
				pfe->fe_logical_len += fe->fe_logical_len;
				pfe->fe_physical_len += fe->fe_physical_len;
				pfe->fe_flags |= FIEMAP_EXTENT_MERGED;
				kmem_free(fe, sizeof (zfs_fiemap_entry_t));
				continue;
			}
		}

		/*
		 * All encrypted extents must also set the encoded flag.
		 */
		if (fe->fe_flags & FIEMAP_EXTENT_DATA_ENCRYPTED)
			fe->fe_flags |= FIEMAP_EXTENT_ENCODED;

		zfs_fiemap_insert(fm, i, fe);
	}

	zfs_fiemap_check_full(fm);

	return (0);
}

/*
 * Start reads for an indirect block's indirect children before they
 * are walked, so the descent overlaps I/O instead of taking one
 * waiting arc_read() per block in turn.  Only indirect children are
 * worth this: a level 0 block pointer is reported from its parent
 * and never fetched.  Children outside the requested range are
 * skipped, as in the walk.
 *
 * Fire and forget, as traverse_prefetcher() does.  A failed prefetch
 * costs nothing; the waiting read in the walk will fetch the block.
 */
static void
zfs_fiemap_prefetch(spa_t *spa, const dnode_phys_t *dnp,
    blkptr_t *cbp, const zbookmark_phys_t *zb, int epb,
    uint64_t start_blk, uint64_t end_blk)
{
	int clevel = zb->zb_level - 1;
	uint64_t cspan;

	if (clevel <= 0)
		return;

	cspan = bp_span_in_blocks(dnp->dn_indblkshift, clevel);

	for (int i = 0; i < epb; i++, cbp++) {
		zbookmark_phys_t pzb;
		arc_flags_t pflags = ARC_FLAG_NOWAIT |
		    ARC_FLAG_PREFETCH | ARC_FLAG_PRESCIENT_PREFETCH;
		uint64_t cblkid = zb->zb_blkid * epb + i;
		uint64_t cfirst = cblkid * cspan;

		if (cfirst >= end_blk)
			break;
		if (BP_IS_HOLE(cbp) || BP_IS_EMBEDDED(cbp))
			continue;
		if (start_blk > cfirst && start_blk - cfirst >= cspan)
			continue;

		SET_BOOKMARK(&pzb, zb->zb_objset, zb->zb_object,
		    clevel, cblkid);
		(void) arc_read(NULL, spa, cbp, NULL, NULL,
		    ZIO_PRIORITY_ASYNC_READ, ZIO_FLAG_CANFAIL,
		    &pflags, &pzb);
	}
}

/*
 * Recursively walk the indirect block tree, invoking the callback for every
 * block pointer traversed.  Indirect blocks are read with
 * ARC_FLAG_WAIT, but zfs_fiemap_prefetch() starts a level's reads
 * before descending, so the waits overlap rather than serializing
 * one block at a time.
 */
static int
zfs_fiemap_visit_indirect(spa_t *spa, const dnode_phys_t *dnp,
    blkptr_t *bp, const zbookmark_phys_t *zb, blkptr_cb_t func,
    void *arg, uint64_t start_blk, uint64_t end_blk)
{
	int error = 0;

	if (zb->zb_blkid > dnp->dn_maxblkid)
		return (0);

	/*
	 * The caller's extent array is already covered, so nothing more can
	 * be reported.  Stop before reading further indirect blocks and
	 * before allocating extents that would only be discarded.  A count
	 * request (fi_extents_max of zero) sets no limit and still walks
	 * the whole range, because it has to return the true count.
	 */
	if (((zfs_fiemap_t *)arg)->fm_full)
		return (0);

	/*
	 * Skip subtrees the caller did not ask about.  A block at
	 * level L covers span level 0 blocks beginning at
	 * zb_blkid * span, so a branch lying outside
	 * [start_blk, end_blk) can be pruned without reading it.
	 */
	uint64_t span = bp_span_in_blocks(dnp->dn_indblkshift,
	    zb->zb_level);
	uint64_t first = zb->zb_blkid * span;
	if (first >= end_blk)
		return (0);
	if (start_blk > first && start_blk - first >= span)
		return (0);

	error = func(spa, NULL, bp, zb, dnp, arg);
	if (error)
		return (error);

	if (BP_GET_LEVEL(bp) > 0 && !BP_IS_HOLE(bp)) {
		arc_flags_t flags = ARC_FLAG_WAIT;
		blkptr_t *cbp;
		int epb = BP_GET_LSIZE(bp) >> SPA_BLKPTRSHIFT;
		arc_buf_t *buf;

		error = arc_read(NULL, spa, bp, arc_getbuf_func, &buf,
		    ZIO_PRIORITY_ASYNC_READ, ZIO_FLAG_CANFAIL, &flags,
		    (zbookmark_phys_t *)zb);
		if (error)
			return (error);

		zfs_fiemap_prefetch(spa, dnp, buf->b_data, zb, epb,
		    start_blk, end_blk);

		cbp = buf->b_data;
		for (int i = 0; i < epb; i++, cbp++) {
			zbookmark_phys_t czb;

			/*
			 * Mapping a large file walks a lot of block
			 * pointers while holding dn_struct_rwlock.
			 * Give the CPU up between children, and let
			 * a signal end the walk, so an ioctl over a
			 * big file is neither a latency spike nor
			 * unkillable.
			 */
			cond_resched();
			if (issig()) {
				error = SET_ERROR(EINTR);
				break;
			}

			SET_BOOKMARK(&czb, zb->zb_objset, zb->zb_object,
			    zb->zb_level - 1, zb->zb_blkid * epb + i);
			error = zfs_fiemap_visit_indirect(spa, dnp, cbp, &czb,
			    func, arg, start_blk, end_blk);
			if (error)
				break;
		}

		arc_buf_destroy(buf, &buf);
	}

	return (error);
}

/*
 * Comparison function for the FIEMAP extent trees.
 */
static int
zfs_fiemap_compare(const void *x1, const void *x2)
{
	const zfs_fiemap_entry_t *fe1 = (const zfs_fiemap_entry_t *)x1;
	const zfs_fiemap_entry_t *fe2 = (const zfs_fiemap_entry_t *)x2;

	return (TREE_CMP(fe1->fe_logical_start, fe2->fe_logical_start));
}

/*
 * The object has no level-zero data blocks at all, so the whole file
 * is one hole.  That is the work zfs_fiemap_add_hole_span() already
 * does for a hole under one indirect block, so route it there rather
 * than keep a second insertion path that would miss the duplicate and
 * overlap checks and the extent cap.
 */
static void
zfs_fiemap_add_sparse(zfs_fiemap_t *fm)
{
	uint64_t blksz = fm->fm_block_size;
	uint64_t size = P2ROUNDUP(fm->fm_file_size, blksz);

	/*
	 * Holes are only emitted for FIEMAP_FLAG_HOLES.  Without it
	 * the fill skips every entry added here, so building them
	 * allocates for a result the caller never sees, and under
	 * NOMERGE that is one allocation per block of the file.
	 */
	if (!(fm->fm_flags & FIEMAP_FLAG_HOLES) || size == 0)
		return;

	zfs_fiemap_add_hole_span(fm, 0, size / blksz);
}

/*
 * Walk the block pointers for the object and assemble a tree of extents
 * describing the logical to physical mapping.
 */
int
zfs_fiemap_assemble(struct inode *ip, zfs_fiemap_t *fm)
{
	znode_t *zp = ITOZ(ip);
	zfsvfs_t *zfsvfs = ZTOZSB(zp);
	zfs_locked_range_t *lr;
	zbookmark_phys_t czb;
	dnode_phys_t *dnp;
	dnode_t *dn;
	spa_t *spa;
	uint64_t lock_len, start_blk, end_blk;
	int error;

	if ((error = zfs_enter_verify_zp(zfsvfs, zp, FTAG)) != 0)
		return (error);

	error = dnode_hold(zfsvfs->z_os, zp->z_id, FTAG, &dn);
	if (error) {
		zfs_exit(zfsvfs, FTAG);
		return (error);
	}

	spa = dmu_objset_spa(dn->dn_objset);

	/*
	 * Width of the vdev id in fe_physical: ceil(log2(top-level
	 * vdevs)).  vdev_children never shrinks (a removed vdev stays
	 * behind as an indirect vdev), so the width only grows, and only
	 * when an add crosses a power of two.
	 */
	spa_config_enter(spa, SCL_VDEV, FTAG, RW_READER);
	fm->fm_vdev_bits =
	    highbit64(spa->spa_root_vdev->vdev_children - 1);
	spa_config_exit(spa, SCL_VDEV, FTAG);

	/*
	 * Block writes to the range being mapped, then force the open
	 * TXG to disk so the on-disk block tree we are about to walk
	 * is complete and stable.  Lock only what was asked for: a
	 * caller mapping part of a file has no reason to stall
	 * writers to the rest of it.
	 *
	 * Give up if the pool suspends while we wait, rather than
	 * parking here holding the range lock, which would block
	 * writers to that range, and the dataset teardown, for as
	 * long as the pool stays suspended.  This mirrors the wait in
	 * zfs_clone_range_locked().
	 */
	lock_len = fm->fm_length;
	if (lock_len == 0 || lock_len > UINT64_MAX - fm->fm_start)
		lock_len = UINT64_MAX - fm->fm_start;

	lr = zfs_rangelock_enter(&zp->z_rangelock, fm->fm_start,
	    lock_len, RL_READER);

	/*
	 * Nothing at or past the end of the file can be mapped, so an
	 * empty file or a request starting at EOF has no extents to
	 * report.  Answer now rather than sync the pool and walk the
	 * tree to arrive at the same empty result.  The range lock is
	 * held, so the size cannot move under this check.
	 */
	fm->fm_file_size = i_size_read(ip);
	if (fm->fm_file_size == 0 ||
	    fm->fm_start >= fm->fm_file_size) {
		zfs_rangelock_exit(lr);
		dnode_rele(dn, FTAG);
		zfs_exit(zfsvfs, FTAG);
		return (0);
	}

	rw_enter(&dn->dn_struct_rwlock, RW_READER);

	/*
	 * Only a dirty dnode needs the sync.  A file with nothing
	 * outstanding is already fully described by the synced tree,
	 * so the common case pays nothing, and mapping a quiescent
	 * file does not force a TXG on everyone else.
	 * dmu_offset_next() gates its sync the same way for
	 * SEEK_HOLE and SEEK_DATA.
	 */
	if (dnode_is_dirty(dn)) {
		rw_exit(&dn->dn_struct_rwlock);

		int failmode = spa_get_failmode(spa);
		int wflags = 0;

		if (failmode == ZIO_FAILURE_MODE_CONTINUE)
			wflags = TXG_WAIT_SUSPEND;

		error = txg_wait_synced_flags(spa_get_dsl(spa), 0,
		    wflags);
		if (error != 0) {
			ASSERT3U(error, ==, ESHUTDOWN);
			zfs_rangelock_exit(lr);
			dnode_rele(dn, FTAG);
			zfs_exit(zfsvfs, FTAG);
			return (SET_ERROR(EIO));
		}

		rw_enter(&dn->dn_struct_rwlock, RW_READER);
	}

	dnp = dn->dn_phys;
	fm->fm_file_size = i_size_read(ip);
	fm->fm_block_size = dnp->dn_datablkszsec << SPA_MINBLOCKSHIFT;

	/*
	 * With only pending dirty buffers the block size may not be set yet;
	 * assume the maximum block size.
	 */
	if (fm->fm_block_size == 0)
		fm->fm_block_size = zfsvfs->z_max_blksz;

	/*
	 * Convert the requested byte range to level 0 blocks so the
	 * walk can prune whole branches that fall outside it.
	 */
	start_blk = fm->fm_start / fm->fm_block_size;
	if (fm->fm_length == 0 ||
	    fm->fm_length > UINT64_MAX - fm->fm_start)
		end_blk = UINT64_MAX;
	else
		end_blk = (fm->fm_start + fm->fm_length +
		    fm->fm_block_size - 1) / fm->fm_block_size;

	SET_BOOKMARK(&czb, dmu_objset_id(dn->dn_objset), dn->dn_object,
	    dnp->dn_nlevels - 1, 0);

	/*
	 * Walk every top-level block pointer in the dnode.  dn_nblkptr is
	 * how many of them there are; fm_copies is how many DVA copies of
	 * each block to report, which zfs_fiemap_cb() applies per block
	 * pointer.  Bounding this loop by fm_copies conflated the two and
	 * would drop whole branches of a dnode carrying more than one top
	 * level pointer, which is the default request (fm_copies == 1).
	 */
	boolean_t any_filled = B_FALSE;
	for (int i = 0; i < dnp->dn_nblkptr; i++) {
		blkptr_t *bp = &dnp->dn_blkptr[i];

		if (BP_GET_FILL(bp) > 0) {
			any_filled = B_TRUE;
			czb.zb_blkid = i;
			error = zfs_fiemap_visit_indirect(spa, dnp,
			    bp, &czb, zfs_fiemap_cb, (void *)fm,
			    start_blk, end_blk);
		}

		if (error)
			break;
	}

	/*
	 * Nothing was filled, so the object has no level-zero data blocks
	 * at all.  Report the file as one sparse range, once: this covers
	 * the whole file, so calling it per top-level pointer would insert
	 * the same extent repeatedly.
	 */
	if (error == 0 && !any_filled)
		zfs_fiemap_add_sparse(fm);

	/*
	 * Only one extent may carry LAST, and it has to be in the
	 * tree emitted last, because a caller stops reading there.
	 * Under FIEMAP_FLAG_COPIES the trees are emitted in order,
	 * so flagging each one would end the caller's scan at the
	 * first copy and hide the rest.  Find the last tree that
	 * holds anything.
	 */
	int lasttree = 0;
	for (int i = fm->fm_copies - 1; i > 0; i--) {
		if (avl_numnodes(&fm->fm_extent_trees[i]) > 0) {
			lasttree = i;
			break;
		}
	}

	{
		avl_tree_t *t = &fm->fm_extent_trees[lasttree];
		zfs_fiemap_entry_t *fe;

		/*
		 * Only an extent reaching the end of the file may be
		 * flagged LAST.  The walk stops at the end of the
		 * requested range, and flagging whatever it collected
		 * last would tell the caller the file ends there.
		 */
		if ((fe = avl_last(t)) != NULL &&
		    fe->fe_logical_start + fe->fe_logical_len >=
		    fm->fm_file_size)
			fe->fe_flags |= FIEMAP_EXTENT_LAST;
	}

	rw_exit(&dn->dn_struct_rwlock);
	zfs_rangelock_exit(lr);

	dnode_rele(dn, FTAG);
	zfs_exit(zfsvfs, FTAG);

	return (error);
}

/*
 * Copy all data (and, with FIEMAP_FLAG_HOLES, hole) extents in the requested
 * range from one assembled tree into the user fiemap_extent_info via the
 * standard kernel helper.
 */
static int
zfs_fiemap_tree_fill(zfs_fiemap_t *fm, int idx, struct fiemap_extent_info *fei,
    uint64_t start, uint64_t length)
{
	avl_tree_t *t = &fm->fm_extent_trees[idx];
	zfs_fiemap_entry_t *fe;
	boolean_t skip_holes = B_TRUE;
	uint64_t end;
	int error = 0;

	if (fm->fm_flags & FIEMAP_FLAG_HOLES)
		skip_holes = B_FALSE;

	if (length >= FIEMAP_MAX_OFFSET - start)
		end = FIEMAP_MAX_OFFSET;
	else
		end = start + length;

	if (start == 0) {
		fe = avl_first(t);
	} else {
		zfs_fiemap_entry_t search;
		avl_index_t aidx;

		search.fe_logical_start = start;
		fe = avl_find(t, &search, &aidx);
		if (fe == NULL)
			fe = avl_nearest(t, aidx, AVL_BEFORE);
		if (fe == NULL)
			fe = avl_first(t);
	}

	while (fe != NULL) {
		uint64_t llen = fe->fe_logical_len;

		if (skip_holes && (fe->fe_flags & FIEMAP_EXTENT_UNWRITTEN)) {
			fe = AVL_NEXT(t, fe);
			continue;
		}

		/*
		 * The search above lands on the nearest extent at or before
		 * the requested start so a straddling extent is caught; skip
		 * any extent that ends at or before start (entirely below the
		 * requested range).
		 */
		if (fe->fe_logical_start + fe->fe_logical_len <= start) {
			fe = AVL_NEXT(t, fe);
			continue;
		}

		if (fe->fe_logical_start >= end)
			break;

		/* Clamp the trailing extent to the file size. */
		if (fe->fe_logical_start < fm->fm_file_size &&
		    fe->fe_logical_start + llen > fm->fm_file_size)
			llen = fm->fm_file_size - fe->fe_logical_start;

		/*
		 * ZFS physical addresses are DVA offsets with ashift
		 * granularity and physical lengths are (possibly compressed)
		 * PSIZEs, so they are not in general aligned to the file
		 * block size the way FIEMAP consumers expect; flag such
		 * extents rather than let them be mistaken for aligned
		 * device ranges (fiemap-tester checks exactly this).
		 */
		uint32_t flags = fe->fe_flags;
		if (!ISP2(fm->fm_block_size) ||
		    ((fe->fe_logical_start | llen | fe->fe_physical_start |
		    fe->fe_physical_len) & (fm->fm_block_size - 1)))
			flags |= FIEMAP_EXTENT_NOT_ALIGNED;

		/*
		 * struct fiemap_extent has no vdev field, so the top-level
		 * vdev id occupies the high fm_vdev_bits bits of the
		 * physical address, starting at the most significant bit
		 * and taking one more bit each time the vdev count crosses
		 * a power of two.  Without this, blocks at equal offsets on
		 * different vdevs (ditto copies in particular) would report
		 * identical addresses, and userspace could not tell the
		 * copies apart or trust equal addresses to mean shared
		 * blocks.  A pool with one top-level vdev takes no bits and
		 * reports the raw offset.  Otherwise the result is an opaque
		 * identifier, useful for equality comparison, not a device
		 * address, and it changes for every block when an add grows
		 * the field.
		 */
		uint64_t phys = fe->fe_physical_start;
		if (fm->fm_vdev_bits != 0)
			phys |= fe->fe_vdev << (64 - fm->fm_vdev_bits);
		error = fiemap_fill_next_extent(fei, fe->fe_logical_start,
		    phys, llen, flags);
		/*
		 * fiemap_fill_next_extent() is a kernel
		 * function and reports failure as a negative
		 * error. This returns a positive ZFS error for
		 * zpl_fiemap() to negate, as
		 * zfs_fiemap_assemble() does, so convert it.
		 * Otherwise that negation turns a failed copy
		 * to the user buffer into a positive value,
		 * which userspace reads as success.
		 */
		if (error < 0)
			return (-error);
		if (error == 1)		/* buffer full or last extent */
			return (0);

		fe = AVL_NEXT(t, fe);
	}

	return (0);
}

/*
 * Fill the user fiemap_extent_info from the assembled extent trees.  By
 * default only the first DVA is reported; FIEMAP_FLAG_COPIES reports all.
 */
int
zfs_fiemap_fill(zfs_fiemap_t *fm, struct fiemap_extent_info *fei,
    uint64_t start, uint64_t length)
{
	int error = 0;

	if (fm->fm_flags & FIEMAP_FLAG_COPIES) {
		for (int i = 0; i < fm->fm_copies; i++) {
			error = zfs_fiemap_tree_fill(fm, i, fei, start, length);
			if (error)
				break;
		}
	} else {
		error = zfs_fiemap_tree_fill(fm, 0, fei, start, length);
	}

	return (error);
}

/*
 * Allocate a zfs_fiemap_t and its extent trees.
 */
zfs_fiemap_t *
zfs_fiemap_create(uint64_t start, uint64_t len, uint64_t flags, uint64_t max)
{
	zfs_fiemap_t *fm;

	fm = kmem_zalloc(sizeof (zfs_fiemap_t), KM_SLEEP);
	fm->fm_copies = 1;
	fm->fm_start = start;
	fm->fm_length = len;
	fm->fm_flags = flags;
	fm->fm_extents_max = max;

	if (fm->fm_flags & FIEMAP_FLAG_COPIES)
		fm->fm_copies = SPA_DVAS_PER_BP;

	for (int i = 0; i < SPA_DVAS_PER_BP; i++) {
		avl_create(&fm->fm_extent_trees[i], zfs_fiemap_compare,
		    sizeof (zfs_fiemap_entry_t),
		    offsetof(zfs_fiemap_entry_t, fe_node));
	}

	return (fm);
}

/*
 * Destroy a zfs_fiemap_t.
 */
void
zfs_fiemap_destroy(zfs_fiemap_t *fm)
{
	for (int i = 0; i < SPA_DVAS_PER_BP; i++) {
		avl_tree_t *t = &fm->fm_extent_trees[i];
		zfs_fiemap_entry_t *fe;
		void *cookie = NULL;

		while ((fe = avl_destroy_nodes(t, &cookie)) != NULL)
			kmem_free(fe, sizeof (zfs_fiemap_entry_t));

		avl_destroy(&fm->fm_extent_trees[i]);
	}

	kmem_free(fm, sizeof (zfs_fiemap_t));
}
