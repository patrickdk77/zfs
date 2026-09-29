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
 * Copyright (c) 2026, Patrick Domack. All rights reserved.
 */

/*
 * Offline deduplication through block cloning ("zpool clonedup").
 *
 * A run has three phases, after an optional counting pass that tells
 * the index which keys appear only once.  The first two are dsl_scan
 * walks in syncing context: phase one indexes the L0 data blocks born
 * since the last completed run, phase two walks the rest of the pool
 * and looks each older block up in that index.  Neither phase reads
 * data.  Phase three runs in an open-context zthr and, for every
 * group of blocks with equal checksum and properties, byte-verifies
 * and redirects the duplicates onto one surviving block with
 * dmu_brt_clone().  Nothing but the progress struct survives a run;
 * the BRT already tracks the sharing.
 *
 * The index is an AVL tree of dsl_clonedup_entry_t, about a hundred
 * bytes per new block.  It is capped by zfs_clonedup_scan_mem_max, or
 * by the same limit a scrub gives its own queues.  When an insert
 * pushes the tree over the cap, the checksum space is split in two,
 * entries outside the half being worked are dropped, and later passes
 * of the same run process the other halves.
 */

#include <sys/dsl_clonedup.h>
#include <sys/dsl_pool.h>
#include <sys/dsl_scan.h>
#include <sys/dsl_dataset.h>
#include <sys/dmu_tx.h>
#include <sys/dnode.h>
#include <sys/zap.h>
#include <sys/spa.h>
#include <sys/spa_impl.h>
#include <sys/vdev_impl.h>
#include <sys/zio_checksum.h>
#include <sys/brt.h>
#include <sys/arc.h>
#include <sys/zio.h>
#include <sys/txg.h>
#include <sys/vdev.h>
#include <sys/dsl_prop.h>
#include <sys/dsl_dir.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_traverse.h>
#include <cityhash.h>

/*
 * Divisor of RAM for the index when zfs_clonedup_scan_mem_max is 0,
 * as zfs_scan_mem_lim_fact is for a scrub.  0 follows
 * zfs_scan_mem_lim_fact.
 */
static uint_t zfs_clonedup_scan_mem_lim_fact = 0;

/*
 * Bytes the index may use.  0 derives the cap from the divisor above,
 * with a 64 MiB floor; an explicit value is used as given.
 */
static uint64_t zfs_clonedup_scan_mem_max = 0;

/*
 * Index blocks whose checksum is not collision resistant (fletcher,
 * edonr).  They are always byte-verified before cloning, so this only
 * trades index memory against coverage.
 */
static int zfs_clonedup_scan_weak_checksums = 1;

/* Debug: drop the index at the apply phase instead of cloning. */
static int zfs_clonedup_scan_noapply = 0;

#define	DCL_MIN_MEM		(64ULL << 20)
#define	DCL_MAX_PARTITION_SHIFT	32

static kmem_cache_t *dsl_clonedup_entry_cache;

void
dsl_clonedup_global_init(void)
{
	dsl_clonedup_entry_cache = kmem_cache_create(
	    "dsl_clonedup_entry", sizeof (dsl_clonedup_entry_t), 0,
	    NULL, NULL, NULL, NULL, NULL, 0);
}

void
dsl_clonedup_global_fini(void)
{
	kmem_cache_destroy(dsl_clonedup_entry_cache);
}

static int
dsl_clonedup_entry_compare(const void *a, const void *b)
{
	const dsl_clonedup_entry_t *x = a;
	const dsl_clonedup_entry_t *y = b;
	int c;

	if ((c = TREE_CMP(x->dce_key, y->dce_key)) != 0)
		return (c);
	if ((c = TREE_CMP(x->dce_prop, y->dce_prop)) != 0)
		return (c);
	c = TREE_CMP(DVA_GET_VDEV(&x->dce_dva),
	    DVA_GET_VDEV(&y->dce_dva));
	if (c != 0)
		return (c);
	c = TREE_CMP(DVA_GET_OFFSET(&x->dce_dva),
	    DVA_GET_OFFSET(&y->dce_dva));
	if (c != 0)
		return (c);
	if ((c = TREE_CMP(x->dce_birth, y->dce_birth)) != 0)
		return (c);
	if ((c = TREE_CMP(x->dce_objset, y->dce_objset)) != 0)
		return (c);
	if ((c = TREE_CMP(x->dce_object, y->dce_object)) != 0)
		return (c);
	return (TREE_CMP(x->dce_blkid, y->dce_blkid));
}

/*
 * Apply order: 0 by checksum, the index order; 1 by source block
 * location, so a group's destinations stay adjacent and share one
 * source read; 2 by destination location.  In modes 1 and 2 a
 * candidate whose chosen source has gone stale is left for the next
 * run.
 */
static uint_t zfs_clonedup_apply_order = 1;

/*
 * Sort order of the apply tree.  The destination dataset leads so a
 * batch stays open across consecutive candidates, because
 * dsl_clonedup_batch_flush() costs a transaction and a previous-txg
 * wait on every dataset change.  The locator tail is unique, so no
 * two entries compare equal.  The source or destination order is
 * fixed per tree by the two wrappers below, since avl takes no
 * context and a global would change under another pool's live tree.
 */
static int
dsl_clonedup_apply_cmp(const void *a, const void *b, boolean_t bysrc)
{
	const dsl_clonedup_entry_t *x = a;
	const dsl_clonedup_entry_t *y = b;
	int c;

	if ((c = TREE_CMP(x->dce_objset, y->dce_objset)) != 0)
		return (c);
	if (bysrc) {
		c = TREE_CMP(x->dce_src->dcs_object,
		    y->dce_src->dcs_object);
		if (c != 0)
			return (c);
		c = TREE_CMP(x->dce_src->dcs_blkid,
		    y->dce_src->dcs_blkid);
		if (c != 0)
			return (c);
	}
	if ((c = TREE_CMP(x->dce_object, y->dce_object)) != 0)
		return (c);
	return (TREE_CMP(x->dce_blkid, y->dce_blkid));
}

static int
dsl_clonedup_apply_compare_src(const void *a, const void *b)
{
	return (dsl_clonedup_apply_cmp(a, b, B_TRUE));
}

static int
dsl_clonedup_apply_compare_dst(const void *a, const void *b)
{
	return (dsl_clonedup_apply_cmp(a, b, B_FALSE));
}

/*
 * Load the saved progress struct.  A missing entry is a pool that
 * never ran clonedup.  Any other problem is logged and treated the
 * same way, so a damaged entry can never keep a pool from importing.
 */
static void
dsl_clonedup_load_phys(dsl_pool_t *dp, dsl_clonedup_phys_t *phys)
{
	objset_t *mos = dp->dp_meta_objset;
	uint64_t intsize, num, *buf;
	int err;

	memset(phys, 0, sizeof (*phys));
	err = zap_length(mos, DMU_POOL_DIRECTORY_OBJECT,
	    DMU_POOL_CLONEDUP_SCAN, &intsize, &num);
	if (err == ENOENT)
		return;
	if (err == 0 && (intsize != sizeof (uint64_t) || num == 0))
		err = SET_ERROR(EINVAL);
	if (err != 0)
		goto bad;

	buf = kmem_zalloc(num * sizeof (uint64_t), KM_SLEEP);
	err = zap_lookup(mos, DMU_POOL_DIRECTORY_OBJECT,
	    DMU_POOL_CLONEDUP_SCAN, sizeof (uint64_t), num, buf);
	if (err == 0) {
		memcpy(phys, buf,
		    MIN(num, DSL_CLONEDUP_PHYS_NUMINTS) *
		    sizeof (uint64_t));
	}
	kmem_free(buf, num * sizeof (uint64_t));
	if (err != 0)
		goto bad;

	if (phys->dclp_version != DSL_CLONEDUP_PHYS_VERSION) {
		zfs_dbgmsg("clonedup: %s has phys version %llu, "
		    "ignoring saved state", spa_name(dp->dp_spa),
		    (u_longlong_t)phys->dclp_version);
		memset(phys, 0, sizeof (*phys));
	}
	return;

bad:
	zfs_dbgmsg("clonedup: %s: cannot read saved state, error %d",
	    spa_name(dp->dp_spa), err);
	memset(phys, 0, sizeof (*phys));
}

static const char *const dsl_clonedup_kstat_names[DCK_NUM] = {
	"verify_reads", "verify_bytes", "clones", "punched",
	"yields", "yield_waits", "index_walks", "match_walks",
	"dst_mounted", "dst_zvol", "dst_owned", "batches",
	"key_collisions", "cksum_collisions", "copies_mismatch",
};

#define	DCL_BUMP(dcl, id, n)	wmsum_add(&(dcl)->dcl_wsums[id], (n))

static int
dsl_clonedup_kstat_update(kstat_t *ksp, int rw)
{
	dsl_clonedup_t *dcl = ksp->ks_private;

	if (rw == KSTAT_WRITE)
		return (SET_ERROR(EACCES));
	for (int i = 0; i < DCK_NUM; i++) {
		dcl->dcl_kstat[i].value.ui64 =
		    wmsum_value(&dcl->dcl_wsums[i]);
	}
	return (0);
}

static void
dsl_clonedup_kstat_create(dsl_clonedup_t *dcl)
{
	char *name;
	kstat_t *ksp;

	for (int i = 0; i < DCK_NUM; i++) {
		wmsum_init(&dcl->dcl_wsums[i], 0);
		(void) strlcpy(dcl->dcl_kstat[i].name,
		    dsl_clonedup_kstat_names[i], KSTAT_STRLEN);
		dcl->dcl_kstat[i].data_type = KSTAT_DATA_UINT64;
	}
	name = kmem_asprintf("zfs/%s", spa_name(dcl->dcl_dp->dp_spa));
	ksp = kstat_create(name, 0, "clonedup", "misc",
	    KSTAT_TYPE_NAMED, DCK_NUM, KSTAT_FLAG_VIRTUAL);
	if (ksp != NULL) {
		ksp->ks_data = dcl->dcl_kstat;
		ksp->ks_private = dcl;
		ksp->ks_update = dsl_clonedup_kstat_update;
		kstat_install(ksp);
	}
	dcl->dcl_ksp = ksp;
	kmem_strfree(name);
}

static void
dsl_clonedup_kstat_destroy(dsl_clonedup_t *dcl)
{
	if (dcl->dcl_ksp != NULL)
		kstat_delete(dcl->dcl_ksp);
	dcl->dcl_ksp = NULL;
	for (int i = 0; i < DCK_NUM; i++)
		wmsum_fini(&dcl->dcl_wsums[i]);
}

int
dsl_clonedup_init(dsl_pool_t *dp)
{
	dsl_clonedup_t *dcl;

	ASSERT0P(dp->dp_clonedup);
	dcl = kmem_zalloc(sizeof (*dcl), KM_SLEEP);
	dcl->dcl_dp = dp;
	mutex_init(&dcl->dcl_lock, NULL, MUTEX_DEFAULT, NULL);
	mutex_init(&dcl->dcl_yield_lock, NULL, MUTEX_DEFAULT, NULL);
	cv_init(&dcl->dcl_yield_cv, NULL, CV_DEFAULT, NULL);
	cv_init(&dcl->dcl_apply_cv, NULL, CV_DEFAULT, NULL);
	dsl_clonedup_load_phys(dp, &dcl->dcl_phys);
	dcl->dcl_phys_written = dcl->dcl_phys;
	dsl_clonedup_kstat_create(dcl);
	dp->dp_clonedup = dcl;
	return (0);
}

static void dsl_clonedup_index_destroy(dsl_clonedup_t *dcl);

void
dsl_clonedup_fini(dsl_pool_t *dp)
{
	dsl_clonedup_t *dcl = dp->dp_clonedup;

	if (dcl == NULL)
		return;
	dsl_clonedup_index_destroy(dcl);
	dsl_clonedup_kstat_destroy(dcl);
	cv_destroy(&dcl->dcl_apply_cv);
	cv_destroy(&dcl->dcl_yield_cv);
	mutex_destroy(&dcl->dcl_yield_lock);
	mutex_destroy(&dcl->dcl_lock);
	kmem_free(dcl, sizeof (*dcl));
	dp->dp_clonedup = NULL;
}

uint64_t
dsl_clonedup_last_txg(dsl_pool_t *dp)
{
	dsl_clonedup_t *dcl = dp->dp_clonedup;

	if (dcl == NULL)
		return (0);
	return (dcl->dcl_phys.dclp_last_txg);
}

/*
 * A restart after an export or a crash begins the current partition
 * again and keeps nothing finer than these fields, so nothing finer
 * is worth a write.  The counters reach the disk with the state
 * change that ends the run.
 */
static boolean_t
dsl_clonedup_phys_moved(const dsl_clonedup_phys_t *a,
    const dsl_clonedup_phys_t *b)
{
	return (a->dclp_state != b->dclp_state ||
	    a->dclp_flags != b->dclp_flags ||
	    a->dclp_phase != b->dclp_phase ||
	    a->dclp_partition_shift != b->dclp_partition_shift ||
	    a->dclp_partition != b->dclp_partition ||
	    a->dclp_min_txg != b->dclp_min_txg ||
	    a->dclp_max_txg != b->dclp_max_txg ||
	    a->dclp_last_txg != b->dclp_last_txg);
}

void
dsl_clonedup_sync_state(dsl_clonedup_t *dcl, dmu_tx_t *tx)
{
	dsl_pool_t *dp = dcl->dcl_dp;
	dsl_clonedup_phys_t phys;

	ASSERT(dmu_tx_is_syncing(tx));
	mutex_enter(&dcl->dcl_lock);
	if (dcl->dcl_phys.dclp_flags & DSF_CLONEDUP_DRYRUN) {
		mutex_exit(&dcl->dcl_lock);
		return;
	}
	dcl->dcl_phys.dclp_version = DSL_CLONEDUP_PHYS_VERSION;
	phys = dcl->dcl_phys;
	mutex_exit(&dcl->dcl_lock);
	if (!dsl_clonedup_phys_moved(&phys, &dcl->dcl_phys_written))
		return;
	VERIFY0(zap_update(dp->dp_meta_objset,
	    DMU_POOL_DIRECTORY_OBJECT, DMU_POOL_CLONEDUP_SCAN,
	    sizeof (uint64_t), DSL_CLONEDUP_PHYS_NUMINTS, &phys, tx));
	dcl->dcl_phys_written = phys;
}

/*
 * Index memory management.
 */
static uint64_t
dsl_clonedup_mem_max(dsl_clonedup_t *dcl)
{
	uint64_t max = zfs_clonedup_scan_mem_max;

	if (max == 0) {
		max = dsl_scan_mem_lim(dcl->dcl_dp->dp_spa,
		    zfs_clonedup_scan_mem_lim_fact);
		max = MAX(max, DCL_MIN_MEM);
	}
	return (max);
}

static void
dsl_clonedup_index_create(dsl_clonedup_t *dcl)
{
	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	ASSERT(!dcl->dcl_index_active);
	avl_create(&dcl->dcl_index, dsl_clonedup_entry_compare,
	    sizeof (dsl_clonedup_entry_t),
	    offsetof(dsl_clonedup_entry_t, dce_node));
	avl_create(&dcl->dcl_apply,
	    zfs_clonedup_apply_order == 2 ?
	    dsl_clonedup_apply_compare_dst :
	    dsl_clonedup_apply_compare_src,
	    sizeof (dsl_clonedup_entry_t),
	    offsetof(dsl_clonedup_entry_t, dce_node));
	dcl->dcl_apply_ready = B_FALSE;
	dcl->dcl_order_have = B_FALSE;
	dcl->dcl_order_counted = B_FALSE;
	dcl->dcl_nentries = 0;
	dcl->dcl_nsrc = 0;
	dcl->dcl_mem_used = 0;
	dcl->dcl_mem_max = dsl_clonedup_mem_max(dcl);
	dcl->dcl_index_active = B_TRUE;
}

static void
dsl_clonedup_entry_free(dsl_clonedup_t *dcl, dsl_clonedup_entry_t *e)
{
	if (e->dce_src != NULL) {
		kmem_free(e->dce_src, sizeof (*e->dce_src));
		dcl->dcl_nsrc--;
		dcl->dcl_mem_used -= sizeof (dsl_clonedup_src_t);
	}
	kmem_cache_free(dsl_clonedup_entry_cache, e);
	dcl->dcl_nentries--;
	dcl->dcl_mem_used -= sizeof (*e);
}

static void
dsl_clonedup_index_destroy(dsl_clonedup_t *dcl)
{
	dsl_clonedup_entry_t *e;
	void *cookie = NULL;

	if (!dcl->dcl_index_active)
		return;
	while ((e = avl_destroy_nodes(&dcl->dcl_index,
	    &cookie)) != NULL)
		dsl_clonedup_entry_free(dcl, e);
	avl_destroy(&dcl->dcl_index);
	cookie = NULL;
	while ((e = avl_destroy_nodes(&dcl->dcl_apply,
	    &cookie)) != NULL)
		dsl_clonedup_entry_free(dcl, e);
	avl_destroy(&dcl->dcl_apply);
	dcl->dcl_apply_ready = B_FALSE;
	ASSERT0(dcl->dcl_nentries);
	ASSERT0(dcl->dcl_nsrc);
	dcl->dcl_index_active = B_FALSE;
	dcl->dcl_gen++;
}

static inline uint64_t
dsl_clonedup_partition_of(uint64_t key, uint64_t shift)
{
	return (shift == 0 ? 0 : key >> (64 - shift));
}

/*
 * Double the partition count and drop every entry that falls outside
 * the half of the current partition being kept.  The other half is
 * revisited by a later pass of this run.
 */
static void
dsl_clonedup_split(dsl_clonedup_t *dcl)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	dsl_clonedup_entry_t *e, *next;
	uint64_t before = dcl->dcl_nentries;

	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	if (p->dclp_partition_shift >= DCL_MAX_PARTITION_SHIFT)
		return;
	p->dclp_partition_shift++;
	p->dclp_partition <<= 1;
	for (e = avl_first(&dcl->dcl_index); e != NULL; e = next) {
		next = AVL_NEXT(&dcl->dcl_index, e);
		if (dsl_clonedup_partition_of(e->dce_key,
		    p->dclp_partition_shift) != p->dclp_partition) {
			avl_remove(&dcl->dcl_index, e);
			dsl_clonedup_entry_free(dcl, e);
			p->dclp_blocks_indexed--;
		}
	}
	dcl->dcl_splits++;
	zfs_dbgmsg("clonedup: %s: index over %llu bytes, split into "
	    "%llu partitions, kept %llu of %llu entries",
	    spa_name(dcl->dcl_dp->dp_spa),
	    (u_longlong_t)dcl->dcl_mem_max,
	    (u_longlong_t)(1ULL << p->dclp_partition_shift),
	    (u_longlong_t)dcl->dcl_nentries, (u_longlong_t)before);
}

/*
 * Block keys.
 */
static uint64_t
dsl_clonedup_bp_key(const blkptr_t *bp)
{
	const zio_cksum_t *c = &bp->blk_cksum;

	return (cityhash4(c->zc_word[0], c->zc_word[1], c->zc_word[2],
	    c->zc_word[3]));
}

static uint64_t
dsl_clonedup_bp_prop(const blkptr_t *bp)
{
	uint64_t p = 0;

	DCE_PROP_SET_LSIZE(p, BP_GET_LSIZE(bp));
	DCE_PROP_SET_PSIZE(p, BP_GET_PSIZE(bp));
	DCE_PROP_SET_COMPRESS(p, BP_GET_COMPRESS(bp));
	DCE_PROP_SET_BYTEORDER(p, BP_GET_BYTEORDER(bp));
	DCE_PROP_SET_CHECKSUM(p, BP_GET_CHECKSUM(bp));
	return (p);
}

/*
 * Whether a block pointer can take part in a run at all.  The dataset
 * level rules (snapshots, the clonedup property) are the caller's.
 */
boolean_t
dsl_clonedup_bp_eligible(spa_t *spa, const blkptr_t *bp,
    const dnode_phys_t *dnp, const zbookmark_phys_t *zb)
{
	enum zio_checksum ck;
	boolean_t ok;
	vdev_t *vd;

	if (zb->zb_level != 0 || dnp == NULL)
		return (B_FALSE);
	if (zb->zb_blkid == DMU_SPILL_BLKID ||
	    zb->zb_blkid == DMU_BONUS_BLKID)
		return (B_FALSE);
	if (dnp->dn_type != DMU_OT_PLAIN_FILE_CONTENTS &&
	    dnp->dn_type != DMU_OT_ZVOL)
		return (B_FALSE);
	if (BP_IS_HOLE(bp) || BP_IS_EMBEDDED(bp) ||
	    BP_IS_REDACTED(bp) || BP_IS_GANG(bp) ||
	    BP_GET_DEDUP(bp) || BP_IS_PROTECTED(bp) ||
	    BP_IS_METADATA(bp) || BP_GET_NDVAS(bp) == 0)
		return (B_FALSE);

	ck = BP_GET_CHECKSUM(bp);
	if (ck >= ZIO_CHECKSUM_FUNCTIONS || ck == ZIO_CHECKSUM_OFF ||
	    ck == ZIO_CHECKSUM_NOPARITY)
		return (B_FALSE);
	if (!(zio_checksum_table[ck].ci_flags &
	    ZCHECKSUM_FLAG_DEDUP) &&
	    !zfs_clonedup_scan_weak_checksums)
		return (B_FALSE);

	/*
	 * vdev_lookup_top() wants a config lock held.  The scan walks
	 * under spa_sync's, the receive walk under none.
	 */
	spa_config_enter(spa, SCL_VDEV, FTAG, RW_READER);
	vd = vdev_lookup_top(spa, DVA_GET_VDEV(&bp->blk_dva[0]));
	ok = vd != NULL && vd->vdev_ops != &vdev_indirect_ops &&
	    !vd->vdev_removing;
	spa_config_exit(spa, SCL_VDEV, FTAG);
	return (ok);
}

static void
dsl_clonedup_entry_fill(dsl_clonedup_entry_t *e, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp,
    uint8_t flags)
{
	memset(e, 0, sizeof (*e));
	e->dce_key = dsl_clonedup_bp_key(bp);
	e->dce_prop = dsl_clonedup_bp_prop(bp);
	e->dce_dva = bp->blk_dva[0];
	e->dce_birth = BP_GET_PHYSICAL_BIRTH(bp);
	e->dce_objset = zb->zb_objset;
	e->dce_object = zb->zb_object;
	e->dce_blkid = zb->zb_blkid;
	e->dce_blkszsec = dnp->dn_datablkszsec;
	e->dce_dntype = dnp->dn_type;
	e->dce_flags = flags;
	if (dnp->dn_type == DMU_OT_ZVOL)
		e->dce_flags |= DCE_F_ZVOL;
}

static void
dsl_clonedup_src_fill(dsl_clonedup_src_t *s, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp,
    uint8_t flags)
{
	memset(s, 0, sizeof (*s));
	s->dcs_dva = bp->blk_dva[0];
	s->dcs_birth = BP_GET_PHYSICAL_BIRTH(bp);
	s->dcs_objset = zb->zb_objset;
	s->dcs_object = zb->zb_object;
	s->dcs_blkid = zb->zb_blkid;
	s->dcs_blkszsec = dnp->dn_datablkszsec;
	s->dcs_dntype = dnp->dn_type;
	s->dcs_flags = flags;
	if (dnp->dn_type == DMU_OT_ZVOL)
		s->dcs_flags |= DCE_F_ZVOL;
}

/*
 * Phase one: remember a block born inside the run's window.  A block
 * seen twice (the walker revisits a dataset after a snapshot destroy
 * or rename) is found by its full locator and ignored.
 */
static void
dsl_clonedup_insert(dsl_clonedup_t *dcl, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp,
    uint8_t flags)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	dsl_clonedup_entry_t probe, *e;
	avl_index_t where;

	dsl_clonedup_entry_fill(&probe, bp, zb, dnp, flags);
	if (dsl_clonedup_partition_of(probe.dce_key,
	    p->dclp_partition_shift) != p->dclp_partition)
		return;
	if (avl_find(&dcl->dcl_index, &probe, &where) != NULL)
		return;

	e = kmem_cache_alloc(dsl_clonedup_entry_cache, KM_SLEEP);
	*e = probe;
	avl_insert(&dcl->dcl_index, e, where);
	dcl->dcl_nentries++;
	dcl->dcl_mem_used += sizeof (*e);
	p->dclp_blocks_indexed++;
	if (dcl->dcl_mem_used > dcl->dcl_mem_max)
		dsl_clonedup_split(dcl);
}

static boolean_t dsl_clonedup_src_better(
    const dsl_clonedup_src_t *a, const dsl_clonedup_src_t *b);

/*
 * Phase two: an older block with the same key and properties as a
 * group becomes that group's source.  Candidates are ranked the way
 * the apply ranks them, so which one wins does not depend on the
 * order the walk reaches them in.
 */
static void
dsl_clonedup_match(dsl_clonedup_t *dcl, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp,
    uint8_t flags)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	dsl_clonedup_entry_t probe, *e;
	dsl_clonedup_src_t cand;
	avl_index_t where;

	memset(&probe, 0, sizeof (probe));
	probe.dce_key = dsl_clonedup_bp_key(bp);
	probe.dce_prop = dsl_clonedup_bp_prop(bp);
	if (dsl_clonedup_partition_of(probe.dce_key,
	    p->dclp_partition_shift) != p->dclp_partition)
		return;

	e = avl_find(&dcl->dcl_index, &probe, &where);
	if (e == NULL)
		e = avl_nearest(&dcl->dcl_index, where, AVL_AFTER);
	if (e == NULL || e->dce_key != probe.dce_key ||
	    e->dce_prop != probe.dce_prop)
		return;

	dsl_clonedup_src_fill(&cand, bp, zb, dnp, flags);
	if (e->dce_src == NULL) {
		e->dce_src = kmem_zalloc(sizeof (*e->dce_src),
		    KM_SLEEP);
		dcl->dcl_nsrc++;
		dcl->dcl_mem_used += sizeof (dsl_clonedup_src_t);
	} else if (!dsl_clonedup_src_better(
	    &cand, e->dce_src)) {
		return;
	}
	*e->dce_src = cand;
}

void
dsl_clonedup_visit(dsl_clonedup_t *dcl, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const dnode_phys_t *dnp,
    uint8_t flags)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	uint64_t birth = BP_GET_PHYSICAL_BIRTH(bp);

	mutex_enter(&dcl->dcl_lock);
	p->dclp_blocks_examined++;
	if (dcl->dcl_index_active) {
		switch (p->dclp_phase) {
		case POOL_CLONEDUP_INDEX:
			if (birth > p->dclp_min_txg)
				dsl_clonedup_insert(dcl, bp, zb, dnp,
				    flags);
			break;
		case POOL_CLONEDUP_MATCH:
			if (birth <= p->dclp_min_txg)
				dsl_clonedup_match(dcl, bp, zb, dnp,
				    flags);
			break;
		default:
			break;
		}
	}
	mutex_exit(&dcl->dcl_lock);
}

/*
 * Run and phase control, driven from dsl_scan_sync().
 */
/*
 * Start a run.  A restart after import keeps the partition being
 * worked and the start time.  Every run keeps dclp_last_txg;
 * everything else starts over.
 */
void
dsl_clonedup_run_setup(dsl_clonedup_t *dcl, uint64_t flags,
    uint64_t min_txg, uint64_t max_txg, boolean_t restart,
    dmu_tx_t *tx)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	dsl_clonedup_phys_t saved;

	mutex_enter(&dcl->dcl_lock);
	saved = *p;
	dsl_clonedup_index_destroy(dcl);
	dcl->dcl_dbg_left = 16;
	memset(p, 0, sizeof (*p));
	p->dclp_version = DSL_CLONEDUP_PHYS_VERSION;
	p->dclp_last_txg = saved.dclp_last_txg;
	if (restart) {
		p->dclp_partition_shift = saved.dclp_partition_shift;
		p->dclp_partition = saved.dclp_partition;
		p->dclp_start_time = saved.dclp_start_time;
	}
	p->dclp_state = DSS_SCANNING;
	p->dclp_flags = flags;
	p->dclp_phase = POOL_CLONEDUP_INDEX;
	DCL_BUMP(dcl, DCK_INDEX_WALKS, 1);
	p->dclp_min_txg = min_txg;
	/*
	 * The finished partitions were walked up to the old bound,
	 * so it stays the bound the next run opens at.  The walks
	 * after a restart use the scan's own, later one.
	 */
	p->dclp_max_txg = restart ? saved.dclp_max_txg : max_txg;
	if (!restart)
		p->dclp_start_time = gethrestime_sec();
	dsl_clonedup_index_create(dcl);
	mutex_exit(&dcl->dcl_lock);
	dsl_clonedup_sync_state(dcl, tx);
}

void
dsl_clonedup_run_done(dsl_clonedup_t *dcl, boolean_t complete,
    dmu_tx_t *tx)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	spa_t *spa = dcl->dcl_dp->dp_spa;

	mutex_enter(&dcl->dcl_lock);
	p->dclp_state = complete ? DSS_FINISHED : DSS_CANCELED;
	p->dclp_end_time = gethrestime_sec();
	p->dclp_phase = POOL_CLONEDUP_NONE;
	/*
	 * A quick run never looked at older data, so the window stays
	 * open for the next default run to match these blocks.
	 */
	if (complete && !(p->dclp_flags &
	    (DSF_CLONEDUP_DRYRUN | DSF_CLONEDUP_QUICK))) {
		p->dclp_last_txg = p->dclp_max_txg;
		spa->spa_clonedup_last_txg = p->dclp_last_txg;
	}
	dsl_clonedup_index_destroy(dcl);
	mutex_exit(&dcl->dcl_lock);
	dsl_clonedup_sync_state(dcl, tx);
}

static dsl_clonedup_next_t
dsl_clonedup_partition_done_locked(dsl_clonedup_t *dcl,
    uint64_t *min_txgp)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;

	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	dsl_clonedup_index_destroy(dcl);
	if (p->dclp_partition + 1 <
	    (1ULL << p->dclp_partition_shift)) {
		p->dclp_partition++;
		p->dclp_phase = POOL_CLONEDUP_INDEX;
		DCL_BUMP(dcl, DCK_INDEX_WALKS, 1);
		dsl_clonedup_index_create(dcl);
		*min_txgp = p->dclp_min_txg;
		return (DCLN_WALK);
	}
	return (DCLN_FINISH);
}

dsl_clonedup_next_t
dsl_clonedup_partition_done(dsl_clonedup_t *dcl, uint64_t *min_txgp,
    dmu_tx_t *tx)
{
	dsl_clonedup_next_t next;

	mutex_enter(&dcl->dcl_lock);
	next = dsl_clonedup_partition_done_locked(dcl, min_txgp);
	mutex_exit(&dcl->dcl_lock);
	dsl_clonedup_sync_state(dcl, tx);
	return (next);
}

dsl_clonedup_next_t
dsl_clonedup_walk_done(dsl_clonedup_t *dcl, uint64_t *min_txgp,
    dmu_tx_t *tx)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;
	dsl_clonedup_next_t next;

	mutex_enter(&dcl->dcl_lock);
	switch (p->dclp_phase) {
	case POOL_CLONEDUP_INDEX:
		if (dcl->dcl_nentries == 0) {
			next = dsl_clonedup_partition_done_locked(dcl,
			    min_txgp);
		} else if ((p->dclp_flags &
		    (DSF_CLONEDUP_FULL | DSF_CLONEDUP_QUICK)) ||
		    p->dclp_min_txg == 0) {
			p->dclp_phase = POOL_CLONEDUP_APPLY;
			next = DCLN_APPLY;
		} else {
			p->dclp_phase = POOL_CLONEDUP_MATCH;
			DCL_BUMP(dcl, DCK_MATCH_WALKS, 1);
			*min_txgp = 0;
			next = DCLN_WALK;
		}
		break;
	case POOL_CLONEDUP_MATCH:
		p->dclp_phase = POOL_CLONEDUP_APPLY;
		next = DCLN_APPLY;
		break;
	default:
		/*
		 * An unexpected phase is not worth a panic: end the
		 * run and leave the data alone.
		 */
		zfs_dbgmsg("clonedup: %s: walk finished in phase "
		    "%llu, ending the run",
		    spa_name(dcl->dcl_dp->dp_spa),
		    (u_longlong_t)p->dclp_phase);
		next = DCLN_FINISH;
		break;
	}
	if (next == DCLN_APPLY) {
		dcl->dcl_apply_total = dcl->dcl_nentries;
		if (zfs_clonedup_scan_noapply)
			dsl_clonedup_index_destroy(dcl);
	}
	mutex_exit(&dcl->dcl_lock);
	dsl_clonedup_sync_state(dcl, tx);
	return (next);
}

boolean_t
dsl_clonedup_apply_done(dsl_clonedup_t *dcl)
{
	boolean_t done;

	mutex_enter(&dcl->dcl_lock);
	done = dcl->dcl_phys.dclp_phase == POOL_CLONEDUP_APPLY &&
	    (!dcl->dcl_index_active || dcl->dcl_nentries == 0) &&
	    dcl->dcl_apply_busy == 0;
	mutex_exit(&dcl->dcl_lock);
	return (done);
}

/*
 * Apply phase: verify and clone, in the open-context zthr.
 */

static int zfs_clonedup_apply_enabled = 1;

/*
 * Clone without reading when both checksums are collision resistant
 * and equal.  Off by default: every candidate is byte compared.
 */
static int zfs_clonedup_apply_trust_checksum = 0;

/*
 * Redirect the head's copy of a block that a snapshot also holds.
 * The snapshot keeps the old block, so the space returns only when
 * the snapshot goes, but every later snapshot shares the survivor.
 */
static int zfs_clonedup_apply_snapheld = 1;

/* All-zero blocks: 0 punches a hole, 1 clones them, 2 leaves them. */
static int zfs_clonedup_apply_zero_blocks = 0;

/* Blocks the apply workers together put in one txg, at most. */
static uint_t zfs_clonedup_apply_blocks_per_txg = 8192;

/*
 * Apply workers.  0 derives one per four cores.  Either way the
 * count is held to DCL_MAX_WORKERS.
 */
static uint_t zfs_clonedup_apply_threads = 0;

/*
 * zfs_clonedup_apply_blocks_per_txg also caps one transaction and one
 * take from the index.  Each clone reserves DCL_BATCH_RESERVE of sync
 * space, and a small pool cannot reserve that for a whole txg of
 * clones, so dsl_clonedup_batch_max() sizes a transaction from the
 * pool.  DCL_BATCH_MIN keeps the smallest pool making progress, and
 * DCL_GROUP_MAX caps a take.
 */
#define	DCL_BATCH_MIN		64
#define	DCL_BATCH_RESERVE	(8ULL << 10)
#define	DCL_GROUP_MAX		1024

/*
 * A destination that is being mounted, unmounted or opened as a
 * volume answers EBUSY for a few ticks.  The open is retried this
 * often, this far apart.
 */
#define	DCL_OPEN_RETRIES	100
#define	DCL_OPEN_RETRY_MS	10

/*
 * Debug: skip the wait for the previous txg before reading the source
 * bps.  That wait makes a writer still holding that txg visible;
 * without it, a writer that frees a source can leave a double
 * allocation.  Never set this on a pool you want to keep.
 */
static int zfs_clonedup_apply_skip_src_wait = 0;

/* Debug: sleep this many ms between verifying and cloning a block. */
static uint_t zfs_clonedup_apply_txg_delay = 0;

/* Debug: sleep this many ms before a worker's final flush. */
static uint_t zfs_clonedup_apply_flush_delay = 0;

/* Debug: sleep this many ms holding a batch's transaction open. */
static uint_t zfs_clonedup_apply_commit_delay = 0;

/*
 * How long an administrative operation waits for the apply thread to
 * let go of the datasets it holds.  After that it fails with EBUSY,
 * as it would if a send or a mount held the dataset.
 */
static uint_t zfs_clonedup_yield_timeout_ms = 10000;

typedef struct dsl_clonedup_group {
	dsl_clonedup_entry_t **g_entries;
	boolean_t	g_borrowed;	/* caller owns g_entries */
	uint_t		g_count;
	uint_t		g_max;
	dsl_clonedup_src_t *g_src;	/* from phase two, or NULL */
	uint64_t	g_key;
	uint64_t	g_prop;
	boolean_t	g_counted;	/* already in dclp_groups */
} dsl_clonedup_group_t;

typedef struct dsl_clonedup_stats {
	uint64_t	s_groups;
	uint64_t	s_candidates;
	uint64_t	s_applied;
	uint64_t	s_saved;
	uint64_t	s_saved_snapheld;
	uint64_t	s_stale;
	uint64_t	s_dirty;
	uint64_t	s_differs;
	uint64_t	s_busy;
	uint64_t	s_policy;
	uint64_t	s_errors;
} dsl_clonedup_stats_t;

typedef struct dsl_clonedup_dsinfo {
	uint64_t	di_head;	/* head of the dsl_dir */
	uint64_t	di_prev_snap_txg;
	uint64_t	di_mode;	/* clonedup property */
	boolean_t	di_snapshot;
	boolean_t	di_inconsistent;
} dsl_clonedup_dsinfo_t;

/*
 * A dataset's clonedup facts are the same for every candidate in it,
 * and reading them means holding the dataset and walking the dsl_dir
 * chain for the clonedup property, so each worker caches them.  The
 * cache is keyed on the dataset object and emptied when the syncing
 * txg moves, so a property change takes effect within a txg.  In
 * index order every dataset holding a candidate is live at once, so
 * DCL_DSINFO_MAX is a memory bound only; past it the rest is read
 * uncached.
 */
#define	DCL_DSINFO_MAX	4096

typedef struct dsl_clonedup_dscache {
	avl_node_t		dc_node;
	uint64_t		dc_dsobj;
	int			dc_err;
	dsl_clonedup_dsinfo_t	dc_info;
} dsl_clonedup_dscache_t;

static int
dsl_clonedup_dscache_compare(const void *a, const void *b)
{
	const dsl_clonedup_dscache_t *x = a;
	const dsl_clonedup_dscache_t *y = b;

	return (TREE_CMP(x->dc_dsobj, y->dc_dsobj));
}

static void
dsl_clonedup_dscache_vacate(dsl_clonedup_worker_t *w)
{
	dsl_clonedup_dscache_t *c;
	void *cookie = NULL;

	while ((c = avl_destroy_nodes(&w->dcw_dscache,
	    &cookie)) != NULL)
		kmem_free(c, sizeof (*c));
}

static void
dsl_clonedup_dscache_init(dsl_clonedup_worker_t *w)
{
	avl_create(&w->dcw_dscache, dsl_clonedup_dscache_compare,
	    sizeof (dsl_clonedup_dscache_t),
	    offsetof(dsl_clonedup_dscache_t, dc_node));
	w->dcw_dscache_txg = 0;
	w->dcw_dscache_ready = B_TRUE;
}

static void
dsl_clonedup_dscache_fini(dsl_clonedup_worker_t *w)
{
	if (!w->dcw_dscache_ready)
		return;
	dsl_clonedup_dscache_vacate(w);
	avl_destroy(&w->dcw_dscache);
	w->dcw_dscache_ready = B_FALSE;
}

boolean_t
dsl_clonedup_bp_same_block(const blkptr_t *a, const blkptr_t *b)
{
	if (BP_IS_HOLE(a) || BP_IS_HOLE(b) || BP_IS_EMBEDDED(a) ||
	    BP_IS_EMBEDDED(b))
		return (B_FALSE);
	return (BP_GET_PHYSICAL_BIRTH(a) ==
	    BP_GET_PHYSICAL_BIRTH(b) &&
	    DVA_EQUAL(&a->blk_dva[0], &b->blk_dva[0]));
}

/* Does the live bp still name the block the index recorded? */
static boolean_t
dsl_clonedup_bp_matches(const blkptr_t *bp, const dva_t *dva,
    uint64_t birth)
{
	if (BP_IS_HOLE(bp) || BP_IS_EMBEDDED(bp))
		return (B_FALSE);
	return (BP_GET_PHYSICAL_BIRTH(bp) == birth &&
	    DVA_EQUAL(&bp->blk_dva[0], dva));
}

/*
 * How many bytes of verify reads may be outstanding.  This is the
 * scrub's own budget, so a clonedup run loads a device no harder
 * than a scrub of the same pool and answers to the same tunables.
 */
static uint64_t
dsl_clonedup_verify_limit(dsl_clonedup_t *dcl)
{
	dsl_scan_t *scn = dcl->dcl_dp->dp_scan;
	uint64_t lim = scn != NULL ? scn->scn_maxinflight_bytes : 0;

	/* dsl_scan_init() sets it at import; this only guards zero */
	return (lim != 0 ? lim : 32ULL << 20);
}

/*
 * An all-zero block is the most common duplicate.  A hole frees it
 * outright and adds no reference to an entry a scrub would then read
 * once per reference.
 */
static void
dsl_clonedup_pend_zero(dsl_clonedup_pend_t *pd,
    dsl_clonedup_stats_t *st)
{
	if (zfs_clonedup_apply_zero_blocks == 2) {
		st->s_policy++;
		pd->dcp_drop = B_TRUE;
	} else {
		pd->dcp_punch = (zfs_clonedup_apply_zero_blocks == 0);
	}
}

/*
 * A pair whose contents differ either shares only the 64-bit key,
 * cityhash4 of the checksum, which costs a wasted read, or shares the
 * full checksum, which is a collision in the checksum itself.  The
 * second is counted and logged apart because it would make
 * zfs_clonedup_apply_trust_checksum unsafe on that checksum.
 */
static void
dsl_clonedup_count_collision(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w,
    const dsl_clonedup_pend_t *pd)
{
	if (!ZIO_CHECKSUM_EQUAL(pd->dcp_sbp.blk_cksum,
	    pd->dcp_dbp.blk_cksum)) {
		DCL_BUMP(dcl, DCK_KEY_COLLISIONS, 1);
		return;
	}
	DCL_BUMP(dcl, DCK_CKSUM_COLLISIONS, 1);
	zfs_dbgmsg("clonedup: checksum collision: objset %llu object "
	    "%llu blkid %llu against objset %llu object %llu blkid "
	    "%llu, checksum %d",
	    (u_longlong_t)w->dcw_batch.dcb_dsobj,
	    (u_longlong_t)pd->dcp_dobject,
	    (u_longlong_t)pd->dcp_blkid,
	    (u_longlong_t)w->dcw_batch.dcb_srcobj,
	    (u_longlong_t)pd->dcp_sobject,
	    (u_longlong_t)pd->dcp_sblkid,
	    (int)BP_GET_CHECKSUM(&pd->dcp_dbp));
}

/*
 * Equal checksums prove equal data only for a collision resistant
 * checksum over identically compressed bytes.
 */
static boolean_t
dsl_clonedup_bp_provably_equal(const blkptr_t *a, const blkptr_t *b)
{
	enum zio_checksum ck = BP_GET_CHECKSUM(a);

	if (BP_IS_HOLE(a) || BP_IS_HOLE(b) || BP_IS_EMBEDDED(a) ||
	    BP_IS_EMBEDDED(b) || BP_IS_REDACTED(a) ||
	    BP_IS_REDACTED(b) || BP_IS_ENCRYPTED(a) ||
	    BP_IS_ENCRYPTED(b))
		return (B_FALSE);
	if (ck != BP_GET_CHECKSUM(b) ||
	    ck >= ZIO_CHECKSUM_FUNCTIONS ||
	    !(zio_checksum_table[ck].ci_flags & ZCHECKSUM_FLAG_DEDUP))
		return (B_FALSE);
	if (BP_GET_COMPRESS(a) != BP_GET_COMPRESS(b) ||
	    BP_GET_PSIZE(a) != BP_GET_PSIZE(b) ||
	    BP_GET_LSIZE(a) != BP_GET_LSIZE(b) ||
	    BP_GET_BYTEORDER(a) != BP_GET_BYTEORDER(b))
		return (B_FALSE);
	return (ZIO_CHECKSUM_EQUAL(a->blk_cksum, b->blk_cksum));
}

/* Give the budget back the moment the read lands, as a scrub does. */
static void
dsl_clonedup_verify_done(zio_t *zio)
{
	spa_t *spa = zio->io_spa;
	int *errp = zio->io_private;

	*errp = zio->io_error;
	mutex_enter(&spa->spa_scrub_lock);
	ASSERT3U(spa->spa_scrub_inflight, >=, zio->io_lsize);
	spa->spa_scrub_inflight -= zio->io_lsize;
	cv_broadcast(&spa->spa_scrub_io_cv);
	mutex_exit(&spa->spa_scrub_lock);
}

/* The reads of one verify pass, issued under one parent zio. */
typedef struct dsl_clonedup_pass {
	zio_t		*dp_pio;
	uint_t		dp_first;
	uint_t		dp_end;
} dsl_clonedup_pass_t;

/* One read, the shape scan_exec_io() uses: raw abd, no ARC. */
static void
dsl_clonedup_verify_read(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, zio_t *pio,
    const blkptr_t *bp, uint64_t object, uint64_t blkid,
    uint64_t dsobj, uint64_t limit, abd_t **abdp, int *errp)
{
	int zf = ZIO_FLAG_CANFAIL | ZIO_FLAG_SCAN_THREAD |
	    ZIO_FLAG_RAW_COMPRESS;
	spa_t *spa = dcl->dcl_dp->dp_spa;
	uint64_t size = BP_GET_PSIZE(bp);
	zbookmark_phys_t zb;

	(void) w;

	mutex_enter(&spa->spa_scrub_lock);
	while (spa->spa_scrub_inflight >= limit)
		cv_wait(&spa->spa_scrub_io_cv, &spa->spa_scrub_lock);
	spa->spa_scrub_inflight += size;
	mutex_exit(&spa->spa_scrub_lock);

	*abdp = abd_alloc_for_io(size, B_FALSE);
	*errp = 0;
	DCL_BUMP(dcl, DCK_VERIFY_READS, 1);
	DCL_BUMP(dcl, DCK_VERIFY_BYTES, size);
	SET_BOOKMARK(&zb, dsobj, object, 0, blkid);
	zio_nowait(zio_read(pio, spa, bp, *abdp, size,
	    dsl_clonedup_verify_done, errp, ZIO_PRIORITY_SCRUB, zf,
	    &zb));
}

static void
dsl_clonedup_verify_one(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    dsl_clonedup_pend_t *pd,
    abd_t *sabd, int serr, dsl_clonedup_stats_t *st)
{
	uint64_t size = BP_GET_PSIZE(&pd->dcp_dbp);

	if (serr != 0 || pd->dcp_derr != 0 || sabd == NULL ||
	    pd->dcp_dabd == NULL) {
		if (pd->dcp_dabd == NULL && pd->dcp_derr == 0) {
			zfs_dbgmsg("clonedup: no destination buffer "
			    "for objset %llu object %llu "
			    "blkid %llu, trusted %d sowner %d",
			    (u_longlong_t)w->dcw_batch.dcb_dsobj,
			    (u_longlong_t)pd->dcp_dobject,
			    (u_longlong_t)pd->dcp_blkid,
			    (int)pd->dcp_trusted,
			    (int)pd->dcp_sowner);
		}
		st->s_errors++;
		pd->dcp_drop = B_TRUE;
	} else if (BP_GET_PSIZE(&pd->dcp_sbp) != size ||
	    BP_GET_LSIZE(&pd->dcp_sbp) !=
	    BP_GET_LSIZE(&pd->dcp_dbp) ||
	    abd_cmp(sabd, pd->dcp_dabd) != 0) {
		st->s_differs++;
		dsl_clonedup_count_collision(dcl, w, pd);
		pd->dcp_drop = B_TRUE;
	} else if (BP_GET_COMPRESS(&pd->dcp_dbp) ==
	    ZIO_COMPRESS_OFF &&
	    abd_cmp_zero(pd->dcp_dabd, size) == 0) {
		dsl_clonedup_pend_zero(pd, st);
	}
	if (!pd->dcp_punch)
		pd->dcp_src_punch = B_FALSE;
}

/*
 * Issue one pass and return where the next one starts.  A pass takes
 * half the inflight budget, so two passes in flight stay within it.
 */
static uint_t
dsl_clonedup_verify_issue(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, uint_t i, uint_t n,
    uint64_t limit, dsl_clonedup_pass_t *ps)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	spa_t *spa = dcl->dcl_dp->dp_spa;
	dsl_clonedup_pend_t *owner = NULL;
	uint64_t held = 0, cap = MAX(1, limit / 2);

	ps->dp_pio = zio_root(spa, NULL, NULL, ZIO_FLAG_CANFAIL);
	ps->dp_first = i;
	for (; i < n; i++) {
		dsl_clonedup_pend_t *pd = &b->dcb_pend[i];
		boolean_t newsrc;
		uint64_t need;

		pd->dcp_sabd = pd->dcp_dabd = NULL;
		pd->dcp_sowner = B_FALSE;
		pd->dcp_serr = pd->dcp_derr = 0;
		if (pd->dcp_trusted)
			continue;
		newsrc = owner == NULL ||
		    !dsl_clonedup_bp_same_block(&pd->dcp_sbp,
		    &owner->dcp_sbp);
		need = BP_GET_PSIZE(&pd->dcp_dbp);
		if (newsrc)
			need += BP_GET_PSIZE(&pd->dcp_sbp);
		if (held != 0 && held + need > cap)
			break;
		held += need;

		if (newsrc) {
			dsl_clonedup_verify_read(dcl, w, ps->dp_pio,
			    &pd->dcp_sbp, pd->dcp_sobject,
			    pd->dcp_sblkid, b->dcb_srcobj, limit,
			    &pd->dcp_sabd, &pd->dcp_serr);
			pd->dcp_sowner = B_TRUE;
			owner = pd;
		}
		dsl_clonedup_verify_read(dcl, w, ps->dp_pio,
		    &pd->dcp_dbp, pd->dcp_dobject,
		    pd->dcp_blkid, b->dcb_dsobj, limit,
		    &pd->dcp_dabd, &pd->dcp_derr);
	}
	ps->dp_end = i;
	return (i);
}

/* Wait for one pass to land and compare everything it read. */
static void
dsl_clonedup_verify_reap(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, dsl_clonedup_pass_t *ps,
    dsl_clonedup_stats_t *st)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	abd_t *sabd = NULL;
	int serr = 0;

	(void) zio_wait(ps->dp_pio);
	ps->dp_pio = NULL;

	for (uint_t j = ps->dp_first; j < ps->dp_end; j++) {
		dsl_clonedup_pend_t *pd = &b->dcb_pend[j];

		if (pd->dcp_trusted)
			continue;
		if (pd->dcp_sowner) {
			if (sabd != NULL)
				abd_free(sabd);
			sabd = pd->dcp_sabd;
			serr = pd->dcp_serr;
		}
		dsl_clonedup_verify_one(dcl, w, pd, sabd, serr, st);
		abd_free(pd->dcp_dabd);
		pd->dcp_dabd = NULL;
	}
	if (sabd != NULL)
		abd_free(sabd);
}

/*
 * Compare every queued pair.  Reads go out at scrub priority and
 * count against spa_scrub_inflight, the budget a scrub paces itself
 * with, up to scn_maxinflight_bytes.  Two passes of half that budget
 * each are kept in flight, so the disk has work while the compare
 * runs and the compare has work while the reads land.  A group's
 * copies share one source read: the index hands them out together,
 * so the previous pend's buffer serves until the source changes.
 */
static void
dsl_clonedup_batch_verify(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w,
    dsl_clonedup_stats_t *st)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	uint64_t limit = dsl_clonedup_verify_limit(dcl);
	uint_t n = b->dcb_count, i = 0, keep = 0;
	dsl_clonedup_pass_t ps[2];
	uint_t cur = 0;

	memset(ps, 0, sizeof (ps));
	if (i < n)
		i = dsl_clonedup_verify_issue(dcl, w, i, n, limit,
		    &ps[0]);
	while (ps[cur].dp_pio != NULL) {
		uint_t nxt = cur ^ 1;

		if (i < n)
			i = dsl_clonedup_verify_issue(dcl, w, i, n,
			    limit, &ps[nxt]);
		dsl_clonedup_verify_reap(dcl, w, &ps[cur], st);
		cur = nxt;
	}

	for (i = 0; i < n; i++) {
		dsl_clonedup_pend_t *pd = &b->dcb_pend[i];

		if (pd->dcp_drop) {
			zfs_clonedup_dst_unlock(pd->dcp_lock);
			continue;
		}
		st->s_candidates++;
		if (keep != i)
			b->dcb_pend[keep] = *pd;
		keep++;
	}
	b->dcb_count = keep;
}

static int
dsl_clonedup_ds_info_read(dsl_pool_t *dp, uint64_t dsobj,
    dsl_clonedup_dsinfo_t *di)
{
	dsl_dataset_t *ds;
	int err;

	memset(di, 0, sizeof (*di));
	dsl_pool_config_enter(dp, FTAG);
	err = dsl_dataset_hold_obj(dp, dsobj, FTAG, &ds);
	if (err == 0) {
		di->di_head =
		    dsl_dir_phys(ds->ds_dir)->dd_head_dataset_obj;
		di->di_prev_snap_txg =
		    dsl_dataset_phys(ds)->ds_prev_snap_txg;
		di->di_snapshot = ds->ds_is_snapshot;
		di->di_inconsistent =
		    (dsl_dataset_phys(ds)->ds_flags &
		    DS_FLAG_INCONSISTENT) != 0;
		di->di_mode = ZFS_CLONEDUP_OFF;
		(void) dsl_prop_get_int_ds(ds,
		    zfs_prop_to_name(ZFS_PROP_CLONEDUP),
		    &di->di_mode);
		dsl_dataset_rele(ds, FTAG);
	}
	dsl_pool_config_exit(dp, FTAG);
	return (err);
}

static int
dsl_clonedup_ds_info(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    uint64_t dsobj,
    dsl_clonedup_dsinfo_t *di)
{
	dsl_pool_t *dp = dcl->dcl_dp;
	uint64_t txg = spa_syncing_txg(dp->dp_spa);
	dsl_clonedup_dscache_t *c, probe;
	avl_index_t where;
	int err;

	if (!w->dcw_dscache_ready)
		return (dsl_clonedup_ds_info_read(dp, dsobj, di));

	if (w->dcw_dscache_txg != txg) {
		dsl_clonedup_dscache_vacate(w);
		w->dcw_dscache_txg = txg;
	}
	probe.dc_dsobj = dsobj;
	c = avl_find(&w->dcw_dscache, &probe, &where);
	if (c != NULL) {
		*di = c->dc_info;
		return (c->dc_err);
	}
	err = dsl_clonedup_ds_info_read(dp, dsobj, di);
	if (avl_numnodes(&w->dcw_dscache) < DCL_DSINFO_MAX) {
		c = kmem_alloc(sizeof (*c), KM_SLEEP);
		c->dc_dsobj = dsobj;
		c->dc_err = err;
		c->dc_info = *di;
		avl_insert(&w->dcw_dscache, c, where);
	}
	return (err);
}

/*
 * The apply thread publishes the datasets it holds, or is about to
 * hold, under dcl_yield_lock.  An operation that a long hold would
 * make fail (destroy, promote, rollback, receive, mount, volume open)
 * brackets itself with dsl_clonedup_yield_begin() and _end(): begin
 * asks the thread to let go of everything and waits for that, and
 * the thread holds nothing again until the last such operation has
 * ended.  The pause is global rather than per dataset because promote
 * cannot name the snapshots it is about to move without repeating
 * its own work.  It counts operations, not txgs, because the
 * thread's own txg waits push txgs through in milliseconds on a
 * quiet pool.
 */
static boolean_t
dsl_clonedup_yield_pending(dsl_clonedup_t *dcl)
{
	return (dcl->dcl_yield_pause != 0);
}

/* zthr_iscancelled() is for the zthr's own thread alone */
static boolean_t
dsl_clonedup_stop(dsl_clonedup_t *dcl, zthr_t *zthr)
{
	if (dcl->dcl_apply_stop)
		return (B_TRUE);
	if (zthr == NULL || !zthr_iscurthread(zthr) ||
	    !zthr_iscancelled(zthr))
		return (B_FALSE);
	dcl->dcl_apply_stop = B_TRUE;
	return (B_TRUE);
}

/*
 * Wait out the yields, then publish dsobj in *heldp.  Waiting while
 * the other slot is published would hold what the yielding operation
 * is about to need, so that case is ERESTART instead: the caller
 * releases everything and comes back.
 */
static int
dsl_clonedup_hold_begin(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    uint64_t *heldp,
    uint64_t dsobj)
{
	boolean_t waited = B_FALSE;

	mutex_enter(&dcl->dcl_yield_lock);
	while (dcl->dcl_yield_pause != 0) {
		if (dsl_clonedup_stop(dcl, dcl->dcl_zthr)) {
			mutex_exit(&dcl->dcl_yield_lock);
			return (SET_ERROR(EINTR));
		}
		if (w->dcw_held_src != 0 ||
		    w->dcw_held_dst != 0) {
			mutex_exit(&dcl->dcl_yield_lock);
			return (SET_ERROR(ERESTART));
		}
		if (!waited) {
			waited = B_TRUE;
			DCL_BUMP(dcl, DCK_YIELD_WAITS, 1);
			zfs_dbgmsg("clonedup hold %llu waits for %u "
			    "operations", (u_longlong_t)dsobj,
			    dcl->dcl_yield_pause);
		}
		(void) cv_timedwait(&dcl->dcl_yield_cv,
		    &dcl->dcl_yield_lock, ddi_get_lbolt() + hz);
	}
	*heldp = dsobj;
	mutex_exit(&dcl->dcl_yield_lock);
	return (0);
}

static void
dsl_clonedup_hold_end(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    uint64_t *heldp)
{
	(void) w;

	mutex_enter(&dcl->dcl_yield_lock);
	*heldp = 0;
	cv_broadcast(&dcl->dcl_yield_cv);
	mutex_exit(&dcl->dcl_yield_lock);
}

/* how many workers hold, or are acquiring, a dataset */
static uint_t
dsl_clonedup_any_held(dsl_clonedup_t *dcl)
{
	uint_t n = 0;

	for (uint_t i = 0; i < dcl->dcl_nworkers; i++) {
		dsl_clonedup_worker_t *w = dcl->dcl_workers[i];

		if (w != NULL &&
		    (w->dcw_held_src != 0 || w->dcw_held_dst != 0))
			n++;
	}
	return (n);
}

/*
 * How many workers hold a destination.  Sources are shared, so
 * dsl_clonedup_any_held() cannot tell two workers sharing a
 * destination from two holding the same source.
 */
static uint_t
dsl_clonedup_dst_held(dsl_clonedup_t *dcl)
{
	uint_t n = 0;

	for (uint_t i = 0; i < dcl->dcl_nworkers; i++) {
		dsl_clonedup_worker_t *w = dcl->dcl_workers[i];

		if (w != NULL && w->dcw_held_dst != 0)
			n++;
	}
	return (n);
}

void
dsl_clonedup_yield_begin(spa_t *spa)
{
	dsl_pool_t *dp = spa_get_dsl(spa);
	dsl_clonedup_t *dcl;
	clock_t deadline;

	if (dp == NULL || (dcl = dp->dp_clonedup) == NULL)
		return;

	mutex_enter(&dcl->dcl_yield_lock);
	dcl->dcl_yield_pause++;
	if (!dsl_clonedup_any_held(dcl)) {
		mutex_exit(&dcl->dcl_yield_lock);
		return;
	}
	zfs_dbgmsg("clonedup yield: %u worker(s) holding, %u of them "
	    "a destination", dsl_clonedup_any_held(dcl),
	    dsl_clonedup_dst_held(dcl));
	DCL_BUMP(dcl, DCK_YIELDS, 1);
	dsl_clonedup_apply_wakeup(spa);
	deadline = ddi_get_lbolt() +
	    MSEC_TO_TICK(zfs_clonedup_yield_timeout_ms);
	while (dsl_clonedup_any_held(dcl)) {
		if (cv_timedwait(&dcl->dcl_yield_cv,
		    &dcl->dcl_yield_lock, deadline) == -1)
			break;
	}
	zfs_dbgmsg("clonedup yield done: %u worker(s) holding",
	    dsl_clonedup_any_held(dcl));
	mutex_exit(&dcl->dcl_yield_lock);
}

void
dsl_clonedup_yield_end(spa_t *spa)
{
	dsl_pool_t *dp = spa_get_dsl(spa);
	dsl_clonedup_t *dcl;

	if (dp == NULL || (dcl = dp->dp_clonedup) == NULL)
		return;

	mutex_enter(&dcl->dcl_yield_lock);
	ASSERT3U(dcl->dcl_yield_pause, >, 0);
	if (dcl->dcl_yield_pause > 0)
		dcl->dcl_yield_pause--;
	cv_broadcast(&dcl->dcl_yield_cv);
	mutex_exit(&dcl->dcl_yield_lock);
}

/*
 * The pool is found from a dataset name; no lock may be held.  A
 * begin whose pool cannot be opened pauses nothing, and its end then
 * finds nothing to release either.
 */
void
dsl_clonedup_yield_begin_name(const char *name)
{
	spa_t *spa;

	if (spa_open(name, &spa, FTAG) != 0)
		return;
	dsl_clonedup_yield_begin(spa);
	spa_close(spa, FTAG);
}

void
dsl_clonedup_yield_end_name(const char *name)
{
	spa_t *spa;

	if (spa_open(name, &spa, FTAG) != 0)
		return;
	dsl_clonedup_yield_end(spa);
	spa_close(spa, FTAG);
}

/*
 * Source datasets are long-held so they cannot be destroyed between
 * reading the source bp and cloning it.  Nothing else is locked: the
 * previous-txg wait in dsl_clonedup_batch_flush() closes the writer
 * race.
 */
static void
dsl_clonedup_src_rele(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w)
{
	if (w->dcw_src_ds != NULL) {
		dsl_dataset_long_rele(w->dcw_src_ds, dcl);
		dsl_dataset_rele(w->dcw_src_ds, dcl);
	}
	w->dcw_src_ds = NULL;
	w->dcw_src_os = NULL;
	w->dcw_src_objset = 0;
	dsl_clonedup_hold_end(dcl, w, &w->dcw_held_src);
}

static int
dsl_clonedup_src_hold(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    uint64_t dsobj,
    objset_t **osp)
{
	dsl_pool_t *dp = dcl->dcl_dp;
	dsl_dataset_t *ds = NULL;
	objset_t *os = NULL;
	int err;

	if (w->dcw_src_ds != NULL &&
	    w->dcw_src_objset == dsobj) {
		*osp = w->dcw_src_os;
		return (0);
	}
	dsl_clonedup_src_rele(dcl, w);
	err = dsl_clonedup_hold_begin(dcl, w, &w->dcw_held_src,
	    dsobj);
	if (err != 0)
		return (err);

	dsl_pool_config_enter(dp, FTAG);
	err = dsl_dataset_hold_obj(dp, dsobj, dcl, &ds);
	if (err == 0) {
		dsl_dataset_long_hold(ds, dcl);
		err = dmu_objset_from_ds(ds, &os);
		if (err != 0) {
			dsl_dataset_long_rele(ds, dcl);
			dsl_dataset_rele(ds, dcl);
		}
	}
	dsl_pool_config_exit(dp, FTAG);
	if (err != 0) {
		dsl_clonedup_hold_end(dcl, w, &w->dcw_held_src);
		return (err);
	}

	w->dcw_src_ds = ds;
	w->dcw_src_os = os;
	w->dcw_src_objset = dsobj;
	*osp = os;
	return (0);
}

/*
 * The first few refusals of a run go to the debug log so that a run
 * which cloned nothing can say why.
 */
static void
dsl_clonedup_dbg(dsl_clonedup_t *dcl, const char *what,
    uint64_t dsobj, uint64_t object, uint64_t blkid,
    const dsl_clonedup_loc_t *src, int err, int res)
{
	uint32_t left;

	do {
		left = dcl->dcl_dbg_left;
		if (left == 0)
			return;
	} while (atomic_cas_32(&dcl->dcl_dbg_left, left, left - 1) !=
	    left);
	zfs_dbgmsg("clonedup %s: objset %llu object %llu blkid %llu "
	    "from objset %llu object %llu blkid %llu err %d res %d",
	    what, (u_longlong_t)dsobj, (u_longlong_t)object,
	    (u_longlong_t)blkid,
	    (u_longlong_t)(src != NULL ? src->l_objset : 0),
	    (u_longlong_t)(src != NULL ? src->l_object : 0),
	    (u_longlong_t)(src != NULL ? src->l_blkid : 0), err, res);
}

static void dsl_clonedup_batch_flush(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w);

static void
dsl_clonedup_dst_rele(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w)
{
	if (w->dcw_dst != NULL)
		zfs_clonedup_dst_close(w->dcw_dst);
	w->dcw_dst = NULL;
	w->dcw_dst_objset = 0;
	w->dcw_dst_object = 0;
	dsl_clonedup_hold_end(dcl, w, &w->dcw_held_dst);
}

/*
 * The handles a batch has parked, hashed by object, since a batch
 * can hold thousands of them and most lookups miss.  Chains hang off
 * the slot array so nothing else has to move.
 */
static uint_t
dsl_clonedup_dst_bucket(const dsl_clonedup_batch_t *b, uint64_t obj)
{
	return ((uint_t)((obj * 0x9E3779B97F4A7C15ULL) >> 32) &
	    b->dcb_dstmask);
}

static void
dsl_clonedup_dst_link(dsl_clonedup_batch_t *b, uint_t slot)
{
	uint_t h = dsl_clonedup_dst_bucket(b, b->dcb_dstobj[slot]);

	b->dcb_dstnext[slot] = b->dcb_dsthash[h];
	b->dcb_dsthash[h] = slot + 1;
}

static void
dsl_clonedup_dst_unlink(dsl_clonedup_batch_t *b, uint_t slot)
{
	uint_t h = dsl_clonedup_dst_bucket(b, b->dcb_dstobj[slot]);
	uint32_t *pp = &b->dcb_dsthash[h];

	while (*pp != 0) {
		uint_t cur = *pp - 1;

		if (cur == slot) {
			*pp = b->dcb_dstnext[slot];
			return;
		}
		pp = &b->dcb_dstnext[cur];
	}
}

static boolean_t
dsl_clonedup_dst_find(const dsl_clonedup_batch_t *b, uint64_t obj,
    uint_t *slotp)
{
	uint32_t e = b->dcb_dsthash[dsl_clonedup_dst_bucket(b, obj)];

	while (e != 0) {
		uint_t slot = e - 1;

		if (b->dcb_dstobj[slot] == obj) {
			*slotp = slot;
			return (B_TRUE);
		}
		e = b->dcb_dstnext[slot];
	}
	return (B_FALSE);
}

static int
dsl_clonedup_dst_hold(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    uint64_t dsobj,
    uint64_t object, zfs_clonedup_dst_t **dstp)
{
	int err, tries;

	dsl_clonedup_batch_t *b = &w->dcw_batch;

	if (w->dcw_dst != NULL &&
	    w->dcw_dst_objset == dsobj &&
	    w->dcw_dst_object == object) {
		*dstp = w->dcw_dst;
		return (0);
	}
	/*
	 * A handle parked for the flush is still open, so look there
	 * before opening another.  In source order the destinations
	 * cycle among the copies of one file, and each would
	 * otherwise pay a fresh zfs_zget.  A batch holds one dataset,
	 * so the object alone identifies the handle.
	 */
	if (b->dcb_count > 0 && b->dcb_dsobj == dsobj) {
		uint_t i;

		if (dsl_clonedup_dst_find(b, object, &i)) {
			zfs_clonedup_dst_t *hit = b->dcb_dsts[i];

			dsl_clonedup_dst_unlink(b, i);
			if (w->dcw_dst != NULL) {
				b->dcb_dsts[i] = w->dcw_dst;
				b->dcb_dstobj[i] = w->dcw_dst_object;
				dsl_clonedup_dst_link(b, i);
			} else {
				uint_t last = --b->dcb_ndst;

				if (last != i) {
					dsl_clonedup_dst_unlink(b,
					    last);
					b->dcb_dsts[i] =
					    b->dcb_dsts[last];
					b->dcb_dstobj[i] =
					    b->dcb_dstobj[last];
					dsl_clonedup_dst_link(b, i);
				}
			}
			w->dcw_dst = hit;
			w->dcw_dst_objset = dsobj;
			w->dcw_dst_object = object;
			*dstp = hit;
			return (0);
		}
	}
	if (b->dcb_count > 0 && (b->dcb_dsobj != dsobj ||
	    b->dcb_ndst == b->dcb_max))
		dsl_clonedup_batch_flush(dcl, w);
	if (b->dcb_count > 0) {
		/*
		 * Same dataset, another object: a queued block still
		 * needs the open handle, so park it for the flush and
		 * leave the dataset published to the yield handshake.
		 */
		if (w->dcw_dst != NULL) {
			b->dcb_dstobj[b->dcb_ndst] =
			    w->dcw_dst_object;
			b->dcb_dsts[b->dcb_ndst] = w->dcw_dst;
			dsl_clonedup_dst_link(b, b->dcb_ndst++);
			w->dcw_dst = NULL;
			w->dcw_dst_objset = 0;
			w->dcw_dst_object = 0;
		}
	} else {
		dsl_clonedup_dst_rele(dcl, w);
		err = dsl_clonedup_hold_begin(dcl, w,
		    &w->dcw_held_dst, dsobj);
		if (err != 0)
			return (err);
	}
	for (tries = 0; ; tries++) {
		err = zfs_clonedup_dst_open(dcl->dcl_dp->dp_spa,
		    dsobj, object, &w->dcw_dst);
		/*
		 * The hold is dropped for the wait: the operation
		 * that answered EBUSY may be waiting for it.
		 */
		if (err != EBUSY || b->dcb_count != 0 ||
		    tries >= DCL_OPEN_RETRIES ||
		    dsl_clonedup_stop(dcl, dcl->dcl_zthr))
			break;
		dsl_clonedup_hold_end(dcl, w, &w->dcw_held_dst);
		delay(MSEC_TO_TICK(DCL_OPEN_RETRY_MS));
		err = dsl_clonedup_hold_begin(dcl, w,
		    &w->dcw_held_dst, dsobj);
		if (err != 0)
			return (err);
	}
	if (err != 0) {
		dsl_clonedup_dbg(dcl, "open", dsobj, object, 0, NULL,
		    err, -1);
		if (b->dcb_count == 0)
			dsl_clonedup_hold_end(dcl, w,
			    &w->dcw_held_dst);
		return (err);
	}
	DCL_BUMP(dcl, zfs_clonedup_dst_kind(w->dcw_dst), 1);
	w->dcw_dst_objset = dsobj;
	w->dcw_dst_object = object;
	*dstp = w->dcw_dst;
	return (0);
}

/* Release everything when asked to; the source is re-held later. */
static void
dsl_clonedup_yield_release(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w)
{
	if (!dsl_clonedup_yield_pending(dcl))
		return;
	dsl_clonedup_batch_flush(dcl, w);
	dsl_clonedup_dst_rele(dcl, w);
	dsl_clonedup_src_rele(dcl, w);
}

static void
dsl_clonedup_entry_to_src(const dsl_clonedup_entry_t *e,
    dsl_clonedup_src_t *s)
{
	memset(s, 0, sizeof (*s));
	s->dcs_dva = e->dce_dva;
	s->dcs_birth = e->dce_birth;
	s->dcs_objset = e->dce_objset;
	s->dcs_object = e->dce_object;
	s->dcs_blkid = e->dce_blkid;
	s->dcs_blkszsec = e->dce_blkszsec;
	s->dcs_dntype = e->dce_dntype;
	s->dcs_flags = e->dce_flags;
}

/*
 * Source preference: a block that is already BRT shared adds no new
 * entry; a snapshot-held or source-only block cannot be rewritten
 * anyway; then the older block; then the lowest locator.
 */
static int
dsl_clonedup_src_rank(const dsl_clonedup_src_t *s)
{
	int rank = 0;

	if (s->dcs_flags & DCE_F_MAYBE_SHARED)
		rank += 4;
	if (s->dcs_flags & (DCE_F_SNAPHELD | DCE_F_SRCONLY))
		rank += 2;
	return (rank);
}

static boolean_t
dsl_clonedup_src_better_ranked(int ra, const dsl_clonedup_src_t *a,
    int rb, const dsl_clonedup_src_t *b)
{
	if (ra != rb)
		return (ra > rb);
	if (a->dcs_birth != b->dcs_birth)
		return (a->dcs_birth < b->dcs_birth);
	if (a->dcs_objset != b->dcs_objset)
		return (a->dcs_objset < b->dcs_objset);
	if (a->dcs_object != b->dcs_object)
		return (a->dcs_object < b->dcs_object);
	return (a->dcs_blkid < b->dcs_blkid);
}

static boolean_t
dsl_clonedup_src_better(const dsl_clonedup_src_t *a,
    const dsl_clonedup_src_t *b)
{
	return (dsl_clonedup_src_better_ranked(
	    dsl_clonedup_src_rank(a), a,
	    dsl_clonedup_src_rank(b), b));
}

/*
 * Pick the surviving copy for a group.  Tier 0 reuses the source of
 * the previous take of the same group, so a group larger than one
 * take still ends up sharing one block.  Tier 1 is the older block
 * the match walk found, tier 2 the best of the entries from index
 * start on.  Returns the tier used, so a caller that finds the block
 * gone can ask for the next one.
 */
static int
dsl_clonedup_group_choose_src(dsl_clonedup_worker_t *w,
    const dsl_clonedup_group_t *g, uint_t start, int tier,
    dsl_clonedup_src_t *src)
{
	int used = 2;

	if (tier <= 0 && w->dcw_group_src_valid &&
	    w->dcw_group_key == g->g_key &&
	    w->dcw_group_prop == g->g_prop) {
		*src = w->dcw_group_src;
		used = 0;
	} else if (tier <= 1 && g->g_src != NULL) {
		*src = *g->g_src;
		used = 1;
	} else {
		dsl_clonedup_src_t cand;
		int rsrc, rcand;

		dsl_clonedup_entry_to_src(g->g_entries[start], src);
		rsrc = dsl_clonedup_src_rank(src);
		for (uint_t i = start + 1; i < g->g_count; i++) {
			dsl_clonedup_entry_to_src(g->g_entries[i],
			    &cand);
			rcand = dsl_clonedup_src_rank(&cand);
			if (dsl_clonedup_src_better_ranked(rcand,
			    &cand, rsrc, src)) {
				*src = cand;
				rsrc = rcand;
			}
		}
	}
	w->dcw_group_src = *src;
	w->dcw_group_key = g->g_key;
	w->dcw_group_prop = g->g_prop;
	w->dcw_group_src_valid = B_TRUE;
	return (used);
}

/*
 * The entry whose block was chosen as source turned out stale.  Move
 * it to index start so the next choice and the apply loop skip it.
 */
static void
dsl_clonedup_group_drop_src(dsl_clonedup_group_t *g, uint_t start,
    const dsl_clonedup_src_t *src)
{
	for (uint_t i = start; i < g->g_count; i++) {
		dsl_clonedup_entry_t *e = g->g_entries[i];

		if (DVA_EQUAL(&e->dce_dva, &src->dcs_dva) &&
		    e->dce_birth == src->dcs_birth) {
			g->g_entries[i] = g->g_entries[start];
			g->g_entries[start] = e;
			return;
		}
	}
}

/*
 * How many entries of one group the apply weighs together.  A group
 * is copies of one block and needs two of them to form a pair, so it
 * floors at two however small the per-txg cap is.  The borrowed
 * buffer in dsl_clonedup_order_index() is sized from here too, and
 * the two must agree or a group overruns the array it was handed.
 */
static uint_t
dsl_clonedup_group_max(void)
{
	return (MIN(MAX(2, zfs_clonedup_apply_blocks_per_txg),
	    DCL_GROUP_MAX));
}

/*
 * Take the next group of equal-content candidates out of the index.
 * The entries now belong to the caller.
 */
static boolean_t
dsl_clonedup_group_take(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    dsl_clonedup_group_t *g,
    dsl_clonedup_entry_t **buf)
{
	dsl_clonedup_entry_t *e, *next;

	memset(g, 0, sizeof (*g));
	g->g_max = dsl_clonedup_group_max();
	g->g_borrowed = (buf != NULL);

	mutex_enter(&dcl->dcl_lock);
	if (!dcl->dcl_index_active || w->dcw_gen != dcl->dcl_gen ||
	    (e = avl_first(&dcl->dcl_index)) == NULL) {
		mutex_exit(&dcl->dcl_lock);
		return (B_FALSE);
	}
	g->g_key = e->dce_key;
	g->g_prop = e->dce_prop;
	g->g_entries = g->g_borrowed ? buf :
	    kmem_alloc(g->g_max * sizeof (*g->g_entries), KM_SLEEP);
	while (e != NULL && e->dce_key == g->g_key &&
	    e->dce_prop == g->g_prop && g->g_count < g->g_max) {
		next = AVL_NEXT(&dcl->dcl_index, e);
		avl_remove(&dcl->dcl_index, e);
		dcl->dcl_nentries--;
		dcl->dcl_mem_used -= sizeof (*e);
		if (e->dce_src != NULL) {
			dcl->dcl_nsrc--;
			dcl->dcl_mem_used -=
			    sizeof (dsl_clonedup_src_t);
			if (g->g_src == NULL)
				g->g_src = e->dce_src;
			else
				kmem_free(e->dce_src,
				    sizeof (*e->dce_src));
			e->dce_src = NULL;
		}
		g->g_entries[g->g_count++] = e;
		e = next;
	}
	dcl->dcl_apply_busy++;
	mutex_exit(&dcl->dcl_lock);
	return (B_TRUE);
}

static void
dsl_clonedup_group_free(dsl_clonedup_group_t *g)
{
	for (uint_t i = 0; i < g->g_count; i++) {
		if (g->g_entries[i] != NULL)
			kmem_cache_free(dsl_clonedup_entry_cache,
			    g->g_entries[i]);
	}
	if (g->g_src != NULL)
		kmem_free(g->g_src, sizeof (*g->g_src));
	if (g->g_entries != NULL && !g->g_borrowed)
		kmem_free(g->g_entries,
		    g->g_max * sizeof (*g->g_entries));
	memset(g, 0, sizeof (*g));
}

/* Count n blocks in tx's txg, or commit tx and return B_FALSE. */
boolean_t
dsl_clonedup_apply_paced(dmu_tx_t *tx, uint_t n)
{
	dsl_pool_t *dp = dmu_tx_pool(tx);
	dsl_clonedup_t *dcl = dp->dp_clonedup;
	uint64_t cap = MAX(1, zfs_clonedup_apply_blocks_per_txg);
	uint64_t txg = dmu_tx_get_txg(tx);
	boolean_t room, newest;

	mutex_enter(&dcl->dcl_lock);
	if (txg > dcl->dcl_apply_txg) {
		dcl->dcl_apply_txg = txg;
		dcl->dcl_apply_in_txg = 0;
	}
	newest = txg == dcl->dcl_apply_txg;
	room = newest && (dcl->dcl_apply_in_txg == 0 ||
	    dcl->dcl_apply_in_txg + n <= cap);
	if (room)
		dcl->dcl_apply_in_txg += n;
	mutex_exit(&dcl->dcl_lock);
	if (room)
		return (B_TRUE);
	dmu_tx_commit(tx);
	if (newest)
		txg_wait_open(dp, txg + 1, B_TRUE);
	return (B_FALSE);
}

static boolean_t
dsl_clonedup_stale(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w)
{
	boolean_t stale;

	mutex_enter(&dcl->dcl_lock);
	stale = w->dcw_gen != dcl->dcl_gen;
	mutex_exit(&dcl->dcl_lock);
	return (stale);
}

static void
dsl_clonedup_stats_fold(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    const dsl_clonedup_stats_t *st)
{
	dsl_clonedup_phys_t *p = &dcl->dcl_phys;

	mutex_enter(&dcl->dcl_lock);
	if (w->dcw_gen != dcl->dcl_gen) {
		mutex_exit(&dcl->dcl_lock);
		return;
	}
	p->dclp_groups += st->s_groups;
	p->dclp_candidates += st->s_candidates;
	p->dclp_applied += st->s_applied;
	p->dclp_bytes_saved += st->s_saved;
	p->dclp_bytes_saved_snapheld += st->s_saved_snapheld;
	p->dclp_skipped_stale += st->s_stale;
	p->dclp_skipped_dirty += st->s_dirty;
	p->dclp_skipped_differs += st->s_differs;
	p->dclp_skipped_busy += st->s_busy;
	p->dclp_skipped_policy += st->s_policy;
	p->dclp_errors += st->s_errors;
	mutex_exit(&dcl->dcl_lock);
}

/*
 * What one transaction may hold.  Each clone reserves
 * DCL_BATCH_RESERVE of sync space, so the batch takes a fraction of
 * the dirty budget and of what the pool can still allocate, capped
 * by zfs_clonedup_apply_blocks_per_txg.
 */
static uint_t
dsl_clonedup_batch_max(dsl_clonedup_t *dcl)
{
	uint64_t want = MAX(1, zfs_clonedup_apply_blocks_per_txg);
	uint64_t room;

	room = MIN(zfs_dirty_data_max / 4,
	    dsl_pool_adjustedsize(dcl->dcl_dp,
	    ZFS_SPACE_CHECK_NORMAL) / 64) / DCL_BATCH_RESERVE;
	return ((uint_t)MIN(want, MAX(DCL_BATCH_MIN, room)));
}

static void
dsl_clonedup_batch_init(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	uint_t nb;

	b->dcb_max = dsl_clonedup_batch_max(dcl);
	b->dcb_count = 0;
	b->dcb_ndst = 0;
	b->dcb_pend = vmem_alloc(sizeof (*b->dcb_pend) * b->dcb_max,
	    KM_SLEEP);
	b->dcb_dsts = vmem_alloc(sizeof (*b->dcb_dsts) * b->dcb_max,
	    KM_SLEEP);
	b->dcb_dstobj = vmem_alloc(sizeof (*b->dcb_dstobj) *
	    b->dcb_max, KM_SLEEP);
	nb = 64;
	while (nb < b->dcb_max)
		nb <<= 1;
	b->dcb_dstmask = nb - 1;
	b->dcb_dsthash = vmem_zalloc(sizeof (*b->dcb_dsthash) * nb,
	    KM_SLEEP);
	b->dcb_dstnext = vmem_alloc(sizeof (*b->dcb_dstnext) *
	    b->dcb_max, KM_SLEEP);
}

static void
dsl_clonedup_batch_fini(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	(void) dcl;

	if (b->dcb_pend != NULL)
		vmem_free(b->dcb_pend,
		    sizeof (*b->dcb_pend) * b->dcb_max);
	if (b->dcb_dsts != NULL)
		vmem_free(b->dcb_dsts,
		    sizeof (*b->dcb_dsts) * b->dcb_max);
	if (b->dcb_dstobj != NULL)
		vmem_free(b->dcb_dstobj,
		    sizeof (*b->dcb_dstobj) * b->dcb_max);
	if (b->dcb_dsthash != NULL)
		vmem_free(b->dcb_dsthash,
		    sizeof (*b->dcb_dsthash) * (b->dcb_dstmask + 1));
	if (b->dcb_dstnext != NULL)
		vmem_free(b->dcb_dstnext,
		    sizeof (*b->dcb_dstnext) * b->dcb_max);
	b->dcb_pend = NULL;
	b->dcb_dsts = NULL;
	b->dcb_dstobj = NULL;
	b->dcb_dsthash = NULL;
	b->dcb_dstnext = NULL;
	b->dcb_dstmask = 0;
	b->dcb_max = 0;
	b->dcb_count = 0;
	b->dcb_ndst = 0;
}

/*
 * Every block of an all-zero group became a hole, so the copy kept as
 * their source holds zeros nothing refers to.  Punch it as well, or a
 * scrub would keep reading it.  The batch is already closed here, so
 * taking a handle on the source dataset cannot re-enter the flush.
 */
static void
dsl_clonedup_batch_punch_src(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, uint_t n,
    dsl_clonedup_stats_t *st)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	boolean_t seen = B_FALSE;
	blkptr_t last;

	ASSERT0(b->dcb_count);
	for (uint_t i = 0; i < n; i++) {
		dsl_clonedup_pend_t *pd = &b->dcb_pend[i];
		dsl_clonedup_dsinfo_t di;
		zfs_clonedup_dst_t *dst;
		zfs_clonedup_result_t res;
		int err;

		if (!pd->dcp_src_punch)
			continue;
		if (seen && dsl_clonedup_bp_same_block(&pd->dcp_sbp,
		    &last))
			continue;
		last = pd->dcp_sbp;
		seen = B_TRUE;

		if (dsl_clonedup_ds_info(dcl, w, b->dcb_srcobj,
		    &di) != 0 || di.di_snapshot ||
		    di.di_inconsistent ||
		    di.di_mode != ZFS_CLONEDUP_ON)
			continue;
		if (dsl_clonedup_dst_hold(dcl, w, b->dcb_srcobj,
		    pd->dcp_sobject, &dst) != 0)
			continue;
		err = zfs_clonedup_dst_apply(dst, pd->dcp_sblkid,
		    &pd->dcp_sbp, b->dcb_sos, pd->dcp_sobject,
		    pd->dcp_sblkid, &pd->dcp_sbp, B_TRUE, &res);
		if (err == 0 && res == ZCR_APPLIED) {
			st->s_applied++;
			st->s_saved += BP_GET_LSIZE(&pd->dcp_sbp);
			DCL_BUMP(dcl, DCK_PUNCHED, 1);
		}
	}
}

/*
 * Send every queued clone out in one transaction.  The wait for the
 * previous txg, which keeps a writer that still holds it from freeing
 * a source under us, is paid once per batch, and a source no writer
 * can reach skips it.  Anything that has moved is dropped; the next
 * run finds the block again.
 */
static void
dsl_clonedup_batch_flush(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	dsl_clonedup_stats_t st = { 0 };
	dsl_pool_t *dp = dcl->dcl_dp;
	boolean_t cloned = B_FALSE;
	uint_t n = b->dcb_count;
	uint64_t txg = 0;
	dmu_tx_t *tx;
	int err;

	if (n == 0)
		return;
	ASSERT3P(b->dcb_sos, ==, w->dcw_src_os);
	if (dsl_clonedup_stale(dcl, w))
		goto release;

	dsl_clonedup_batch_verify(dcl, w, &st);
	n = b->dcb_count;
	if (n == 0)
		goto release;
	if (b->dcb_dryrun) {
		for (uint_t i = 0; i < n; i++) {
			dsl_clonedup_pend_t *pd = &b->dcb_pend[i];

			st.s_applied++;
			if (pd->dcp_snapheld)
				st.s_saved_snapheld += pd->dcp_dasize;
			else
				st.s_saved += pd->dcp_dasize;
		}
		goto release;
	}

	do {
		tx = dmu_tx_create(b->dcb_os);
		for (uint_t i = 0; i < n; i++) {
			dsl_clonedup_pend_t *pd = &b->dcb_pend[i];

			zfs_clonedup_dst_tx_hold(tx, pd->dcp_dst,
			    pd->dcp_blkid, pd->dcp_blksz,
			    pd->dcp_punch);
		}
		err = dmu_tx_assign(tx, DMU_TX_WAIT);
		if (err != 0) {
			dmu_tx_abort(tx);
			st.s_errors += n;
			goto release;
		}
	} while (!dsl_clonedup_apply_paced(tx, n));
	txg = dmu_tx_get_txg(tx);
	if (zfs_clonedup_apply_commit_delay != 0)
		delay(MSEC_TO_TICK(zfs_clonedup_apply_commit_delay));
	if (!b->dcb_src_stable && !zfs_clonedup_apply_skip_src_wait) {
		err = txg_wait_synced_flags(dp, txg - 1,
		    TXG_WAIT_SUSPEND);
		if (err != 0) {
			dmu_tx_commit(tx);
			st.s_errors += n;
			goto release;
		}
	}
	/*
	 * The apply hands destinations that share a source to the
	 * batch together, so read and check that source once for the
	 * run of them instead of once per destination.  They are all
	 * in this transaction, so nothing can change between them.
	 */
	blkptr_t sval;
	zfs_clonedup_result_t sres = ZCR_ERROR;
	uint64_t sobj = 0, sblkid = 0;
	boolean_t shave = B_FALSE;

	for (uint_t i = 0; i < n; i++) {
		dsl_clonedup_pend_t *pd = &b->dcb_pend[i];
		zfs_clonedup_result_t res;

		if (!pd->dcp_punch && (!shave ||
		    pd->dcp_sobject != sobj ||
		    pd->dcp_sblkid != sblkid)) {
			err = zfs_clonedup_src_validate(b->dcb_sos,
			    pd->dcp_sobject, pd->dcp_sblkid,
			    &pd->dcp_sbp, &sval, &sres);
			if (err != 0)
				sres = ZCR_ERROR;
			sobj = pd->dcp_sobject;
			sblkid = pd->dcp_sblkid;
			shave = B_TRUE;
		}
		if (!pd->dcp_punch && sres != ZCR_APPLIED) {
			res = sres;
		} else {
			err = zfs_clonedup_dst_finish(pd->dcp_dst,
			    pd->dcp_blkid, pd->dcp_blksz, b->dcb_sos,
			    pd->dcp_sobject, pd->dcp_sblkid,
			    &pd->dcp_sbp,
			    pd->dcp_punch ? NULL : &sval,
			    pd->dcp_punch, tx, &res);
		}
		switch (res) {
		case ZCR_APPLIED:
			st.s_applied++;
			if (pd->dcp_snapheld)
				st.s_saved_snapheld += pd->dcp_dasize;
			else
				st.s_saved += pd->dcp_dasize;
			DCL_BUMP(dcl, pd->dcp_punch ? DCK_PUNCHED :
			    DCK_CLONES, 1);
			break;
		case ZCR_SRC_STALE:
		case ZCR_DST_STALE:
			st.s_stale++;
			break;
		case ZCR_SRC_DIRTY:
		case ZCR_DST_DIRTY:
			st.s_dirty++;
			break;
		default:
			st.s_errors++;
			break;
		}
		if (res != ZCR_APPLIED) {
			dsl_clonedup_loc_t sl = { b->dcb_srcobj,
			    pd->dcp_sobject, pd->dcp_sblkid };

			dsl_clonedup_dbg(dcl, "apply", b->dcb_dsobj,
			    pd->dcp_dobject, pd->dcp_blkid, &sl, err,
			    res);
		}
		if (res != ZCR_APPLIED || !pd->dcp_punch)
			pd->dcp_src_punch = B_FALSE;
	}
	dmu_tx_commit(tx);
	cloned = B_TRUE;
	DCL_BUMP(dcl, DCK_BATCHES, 1);
release:
	for (uint_t i = 0; i < n; i++)
		zfs_clonedup_dst_unlock(b->dcb_pend[i].dcp_lock);
	for (uint_t i = 0; i < b->dcb_ndst; i++)
		zfs_clonedup_dst_close(b->dcb_dsts[i]);
	if (b->dcb_ndst != 0) {
		memset(b->dcb_dsthash, 0,
		    sizeof (*b->dcb_dsthash) * (b->dcb_dstmask + 1));
	}
	b->dcb_ndst = 0;
	b->dcb_count = 0;
	if (cloned)
		dsl_clonedup_batch_punch_src(dcl, w, n, &st);
	dsl_clonedup_stats_fold(dcl, w, &st);
}

/*
 * Take the destination range lock and queue the block.  The lock is
 * held until the batch commits, so the destination cannot move under
 * the clone and no transaction is assigned before it is taken.  A
 * batch that already holds locks never waits for another.  EAGAIN
 * asks the caller to flush the batch and try the block again.
 */
static int
dsl_clonedup_batch_add(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    zfs_clonedup_dst_t *dst,
    uint64_t dsobj, uint64_t srcobj, objset_t *sos, boolean_t stable,
    uint64_t object, uint64_t blkid, uint64_t blksz,
    const blkptr_t *dexp,
    const blkptr_t *sexp, uint64_t sobject, uint64_t sblkid,
    uint64_t dasize, boolean_t snapheld, boolean_t trusted,
    boolean_t src_punch, boolean_t dryrun,
    zfs_clonedup_result_t *resp)
{
	dsl_clonedup_batch_t *b = &w->dcw_batch;
	dsl_clonedup_pend_t *pd;
	boolean_t ready = B_FALSE;
	void *lock = NULL;
	int err;

	if (dryrun) {
		/* nothing is written, so nothing is locked */
		ready = B_TRUE;
	} else {
		err = zfs_clonedup_dst_prepare(dst, blkid, dexp, sos,
		    b->dcb_count > 0, &ready, &lock, resp);
		if (err != 0 || !ready)
			return (err);
	}

	if (b->dcb_count == 0) {
		b->dcb_dsobj = dsobj;
		b->dcb_srcobj = srcobj;
		b->dcb_os = zfs_clonedup_dst_objset(dst);
		b->dcb_sos = sos;
		b->dcb_src_stable = stable;
		b->dcb_dryrun = dryrun;
	}
	pd = &b->dcb_pend[b->dcb_count++];
	pd->dcp_dst = dst;
	pd->dcp_lock = lock;
	pd->dcp_blkid = blkid;
	pd->dcp_blksz = blksz;
	pd->dcp_dobject = object;
	pd->dcp_dbp = *dexp;
	pd->dcp_sobject = sobject;
	pd->dcp_sblkid = sblkid;
	pd->dcp_sbp = *sexp;
	pd->dcp_dasize = dasize;
	pd->dcp_snapheld = snapheld;
	pd->dcp_trusted = trusted;
	pd->dcp_src_punch = src_punch && !trusted;
	pd->dcp_punch = B_FALSE;
	pd->dcp_drop = B_FALSE;
	pd->dcp_sabd = pd->dcp_dabd = NULL;
	*resp = ZCR_QUEUED;

	if (b->dcb_count >= b->dcb_max)
		dsl_clonedup_batch_flush(dcl, w);
	return (0);
}

/*
 * The scan saw this block, but the object may have been truncated or
 * rewritten smaller since.  dmu_read_l0_bps() does not tolerate an
 * offset past the end of an object: it reaches zfs_panic_recover(),
 * which panics on a default system.  Bound every read by what the
 * object holds now, sources and destinations alike: a file rewritten
 * smaller keeps a length the destination checks pass, while its one
 * block is no longer the size the scan recorded.
 */
static int
dsl_clonedup_src_in_range(objset_t *os, uint64_t object,
    uint64_t blkid,
    uint64_t blksz)
{
	dmu_object_info_t doi;
	int err;

	err = dmu_object_info(os, object, &doi);
	if (err != 0)
		return (err);
	if (doi.doi_data_block_size != blksz ||
	    (blkid + 1) * blksz > doi.doi_max_offset)
		return (SET_ERROR(ESTALE));
	return (0);
}

static void
dsl_clonedup_group_process(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w,
    dsl_clonedup_group_t *g, zthr_t *zthr)
{
	dsl_clonedup_stats_t st = { 0 };
	dsl_clonedup_src_t src;
	objset_t *sos;
	blkptr_t sbp, dbp;
	uint64_t sblksz;
	dsl_clonedup_dsinfo_t sdi;
	boolean_t dryrun, src_stable = B_FALSE;
	boolean_t counted = g->g_counted, trusted, src_punch;
	uint_t start = 0;
	int tier = 0, used;
	size_t nb;
	int err;

	mutex_enter(&dcl->dcl_lock);
	dryrun = (dcl->dcl_phys.dclp_flags &
	    DSF_CLONEDUP_DRYRUN) != 0;
	mutex_exit(&dcl->dcl_lock);

again:
	if (start >= g->g_count)
		goto out;
	used = dsl_clonedup_group_choose_src(w, g, start, tier, &src);
	sblksz = (uint64_t)src.dcs_blkszsec << SPA_MINBLOCKSHIFT;
	src_punch = !dryrun && zfs_clonedup_apply_zero_blocks == 0 &&
	    !(src.dcs_flags & (DCE_F_SNAPHELD | DCE_F_SRCONLY));

	if (w->dcw_batch.dcb_count > 0 &&
	    w->dcw_batch.dcb_srcobj != src.dcs_objset)
		dsl_clonedup_batch_flush(dcl, w);
	err = dsl_clonedup_src_hold(dcl, w, src.dcs_objset, &sos);
	if (err == ERESTART) {
		dsl_clonedup_yield_release(dcl, w);
		goto again;
	}
	if (err == 0)
		err = dsl_clonedup_src_in_range(sos, src.dcs_object,
		    src.dcs_blkid, sblksz);
	if (err == 0) {
		nb = 1;
		err = dmu_read_l0_bps(sos, src.dcs_object,
		    src.dcs_blkid * sblksz, sblksz, &sbp, &nb);
		if (err == 0 && (nb != 1 ||
		    !dsl_clonedup_bp_matches(&sbp, &src.dcs_dva,
		    src.dcs_birth)))
			err = SET_ERROR(ESTALE);
	}
	if (err != 0) {
		/* try the next tier, then the next entry */
		w->dcw_group_src_valid = B_FALSE;
		if (used < 2) {
			tier = used + 1;
			goto again;
		}
		dsl_clonedup_group_drop_src(g, start, &src);
		if (err == EAGAIN)
			st.s_dirty++;
		else
			st.s_stale++;
		if (++start < g->g_count)
			goto again;
		goto out;
	}
	src_stable = dsl_clonedup_ds_info(dcl, w, src.dcs_objset,
	    &sdi) == 0 && sdi.di_snapshot;

	/* a group has work when some entry names another block */
	for (uint_t i = start; i < g->g_count && !counted; i++) {
		dsl_clonedup_entry_t *e = g->g_entries[i];

		if (!DVA_EQUAL(&e->dce_dva, &src.dcs_dva) ||
		    e->dce_birth != src.dcs_birth) {
			st.s_groups++;
			counted = B_TRUE;
		}
	}

	for (uint_t i = start; i < g->g_count &&
	    !dsl_clonedup_stop(dcl, zthr) &&
	    !dsl_clonedup_stale(dcl, w);
	    i++) {
		dsl_clonedup_entry_t *e = g->g_entries[i];
		uint64_t dasize = 0;
		uint64_t dblksz =
		    (uint64_t)e->dce_blkszsec << SPA_MINBLOCKSHIFT;
		uint64_t dsobj = e->dce_objset;
		dsl_clonedup_dsinfo_t di;
		zfs_clonedup_dst_t *dst;
		zfs_clonedup_result_t res;

redo:
		if (dsl_clonedup_yield_pending(dcl) ||
		    w->dcw_src_ds == NULL) {
			dsl_clonedup_batch_flush(dcl, w);
			dsl_clonedup_yield_release(dcl, w);
			err = dsl_clonedup_src_hold(dcl, w,
			    src.dcs_objset, &sos);
			if (err == ERESTART) {
				dsl_clonedup_yield_release(dcl, w);
				goto redo;
			}
			if (err != 0) {
				/* source dataset gone: re-pick */
				w->dcw_group_src_valid = B_FALSE;
				start = i;
				tier = 2;
				goto again;
			}
		}
		if (e->dce_flags & DCE_F_SRCONLY)
			continue;
		if (DVA_EQUAL(&e->dce_dva, &src.dcs_dva) &&
		    e->dce_birth == src.dcs_birth)
			continue;
		if (dsl_clonedup_ds_info(dcl, w, dsobj, &di) != 0) {
			st.s_stale++;
			continue;
		}
		if (e->dce_flags & DCE_F_SNAPHELD) {
			if (!zfs_clonedup_apply_snapheld) {
				st.s_policy++;
				continue;
			}
			if (di.di_snapshot) {
				dsobj = di.di_head;
				if (dsl_clonedup_ds_info(dcl, w,
				    dsobj, &di) != 0) {
					st.s_stale++;
					continue;
				}
			}
		}
		if (di.di_snapshot || di.di_mode != ZFS_CLONEDUP_ON ||
		    di.di_inconsistent) {
			st.s_policy++;
			continue;
		}

		err = dsl_clonedup_dst_hold(dcl, w, dsobj,
		    e->dce_object, &dst);
		if (err == ERESTART) {
			dsl_clonedup_yield_release(dcl, w);
			goto redo;
		}
		if (err == EBUSY) {
			st.s_busy++;
			continue;
		}
		if (err == EROFS || err == EPERM) {
			st.s_policy++;
			continue;
		}
		if (err != 0) {
			st.s_stale++;
			continue;
		}
		if (!zfs_clonedup_dst_exclusive(dst)) {
			mutex_enter(&dcl->dcl_lock);
			w->dcw_claim_dst = 0;
			mutex_exit(&dcl->dcl_lock);
		}
		if (w->dcw_src_ds == NULL) {
			err = dsl_clonedup_src_hold(dcl, w,
			    src.dcs_objset, &sos);
			if (err == ERESTART) {
				dsl_clonedup_yield_release(dcl, w);
				goto redo;
			}
			if (err != 0) {
				w->dcw_group_src_valid = B_FALSE;
				start = i;
				tier = 2;
				goto again;
			}
		}

		nb = 1;
		err = dsl_clonedup_src_in_range(
		    zfs_clonedup_dst_objset(dst), e->dce_object,
		    e->dce_blkid, dblksz);
		if (err != 0) {
			st.s_stale++;
			continue;
		}
		err = dmu_read_l0_bps(zfs_clonedup_dst_objset(dst),
		    e->dce_object, e->dce_blkid * dblksz, dblksz,
		    &dbp, &nb);
		if (err == EAGAIN) {
			st.s_dirty++;
			continue;
		}
		if (err != 0 || nb != 1 ||
		    !dsl_clonedup_bp_matches(&dbp, &e->dce_dva,
		    e->dce_birth)) {
			st.s_stale++;
			continue;
		}
		if (dsl_clonedup_bp_same_block(&dbp, &sbp))
			continue;
		/*
		 * The clone installs the source bp whole, so the
		 * destination gets the source's copies.  Fewer lose
		 * redundancy the copies property asked for, more cost
		 * space it did not.
		 */
		if (BP_GET_NDVAS(&sbp) != BP_GET_NDVAS(&dbp)) {
			DCL_BUMP(dcl, DCK_COPIES_MISMATCH, 1);
			st.s_policy++;
			continue;
		}
		/*
		 * A redirect frees what the destination block
		 * occupies on disk across all its copies, not the
		 * record size it presents.  On a compressed dataset
		 * the two differ by the compression ratio.
		 */
		dasize = BP_GET_ASIZE(&dbp);
		trusted = zfs_clonedup_apply_trust_checksum &&
		    dsl_clonedup_bp_provably_equal(&sbp, &dbp);

		if (zfs_clonedup_apply_txg_delay != 0)
			delay(MSEC_TO_TICK(
			    zfs_clonedup_apply_txg_delay));

		err = dsl_clonedup_batch_add(dcl, w, dst, dsobj,
		    src.dcs_objset, sos, src_stable, e->dce_object,
		    e->dce_blkid, dblksz,
		    &dbp, &sbp, src.dcs_object, src.dcs_blkid, dasize,
		    (e->dce_flags & DCE_F_SNAPHELD) != 0, trusted,
		    src_punch, dryrun, &res);
		if (err == EAGAIN) {
			dsl_clonedup_batch_flush(dcl, w);
			goto redo;
		}
		if (err == EPERM || err == EROFS || err == EDQUOT ||
		    err == EXDEV) {
			st.s_policy++;
			continue;
		}
		if (err != 0) {
			st.s_errors++;
			continue;
		}
		switch (res) {
		case ZCR_QUEUED:
			break;
		case ZCR_DST_STALE:
			st.s_stale++;
			break;
		case ZCR_DST_DIRTY:
			st.s_dirty++;
			break;
		default:
			st.s_errors++;
			break;
		}
		if (res != ZCR_QUEUED) {
			dsl_clonedup_loc_t sl = { src.dcs_objset,
			    src.dcs_object, src.dcs_blkid };

			dsl_clonedup_dbg(dcl, "apply", dsobj,
			    e->dce_object, e->dce_blkid, &sl, err,
			    res);
		}
	}

out:
	if (w->dcw_batch.dcb_count == 0)
		dsl_clonedup_dst_rele(dcl, w);
	dsl_clonedup_stats_fold(dcl, w, &st);
}

/*
 * Decide one group's source and move its destinations into the apply
 * tree.  The choice costs no I/O: the older block from phase two if
 * the group has one, otherwise the best of the group's own copies.
 * It is not validated here: a stale source is caught when the apply
 * reads its bp, and the candidate is left for the next run.
 */
static uint_t
dsl_clonedup_group_decide(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, dsl_clonedup_group_t *g)
{
	dsl_clonedup_src_t src;
	uint_t moved = 0;

	/*
	 * A group larger than one take arrives once per take, and
	 * every take must reach the same source or each keeps a
	 * survivor of its own.  dsl_clonedup_group_choose_src()
	 * caches the last source by key and prop for that.  The cache
	 * is dropped at the end of the pass, not here.
	 */
	(void) dsl_clonedup_group_choose_src(w, g, 0, 0, &src);

	for (uint_t i = 0; i < g->g_count; i++) {
		dsl_clonedup_entry_t *e = g->g_entries[i];

		if (e->dce_flags & DCE_F_SRCONLY)
			continue;
		if (DVA_EQUAL(&e->dce_dva, &src.dcs_dva) &&
		    e->dce_birth == src.dcs_birth)
			continue;
		e->dce_src = kmem_alloc(sizeof (src), KM_SLEEP);
		*e->dce_src = src;
		mutex_enter(&dcl->dcl_lock);
		if (w->dcw_gen != dcl->dcl_gen) {
			mutex_exit(&dcl->dcl_lock);
			kmem_free(e->dce_src, sizeof (src));
			e->dce_src = NULL;
			break;
		}
		avl_add(&dcl->dcl_apply, e);
		dcl->dcl_nentries++;
		dcl->dcl_nsrc++;
		dcl->dcl_mem_used += sizeof (*e) + sizeof (src);
		mutex_exit(&dcl->dcl_lock);
		g->g_entries[i] = NULL;
		moved++;
	}
	return (moved);
}

/*
 * Empty the checksum-ordered index into the apply tree.  Runs once,
 * before the first clone of the partition, and issues no I/O.
 */
static void
dsl_clonedup_order_index(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, zthr_t *zthr)
{
	dsl_clonedup_group_t g;
	dsl_clonedup_entry_t **buf;
	uint_t bufmax = dsl_clonedup_group_max();

	/*
	 * One array serves every group this pass takes, instead of an
	 * 8 KiB allocation per group across the whole index.  Nothing
	 * here outlives the iteration.
	 */
	buf = kmem_alloc(bufmax * sizeof (*buf), KM_SLEEP);
	while (!dsl_clonedup_stop(dcl, zthr) &&
	    dsl_clonedup_group_take(dcl, w, &g, buf)) {
		uint64_t key = g.g_key, prop = g.g_prop;
		uint_t moved;

		moved = dsl_clonedup_group_decide(dcl, w, &g);
		dsl_clonedup_group_free(&g);
		mutex_enter(&dcl->dcl_lock);
		if (dcl->dcl_apply_busy > 0)
			dcl->dcl_apply_busy--;
		if (w->dcw_gen != dcl->dcl_gen) {
			mutex_exit(&dcl->dcl_lock);
			break;
		}
		if (!dcl->dcl_order_have ||
		    key != dcl->dcl_order_key ||
		    prop != dcl->dcl_order_prop) {
			dcl->dcl_order_key = key;
			dcl->dcl_order_prop = prop;
			dcl->dcl_order_have = B_TRUE;
			dcl->dcl_order_counted = B_FALSE;
		}
		if (moved > 0 && !dcl->dcl_order_counted) {
			dcl->dcl_phys.dclp_groups++;
			dcl->dcl_order_counted = B_TRUE;
		}
		mutex_exit(&dcl->dcl_lock);
	}
	/*
	 * A cancelled pass leaves the rest of the index where it is,
	 * and the next run of the thread resumes it.  Marking it done
	 * would strand every entry it has not reached.
	 */
	mutex_enter(&dcl->dcl_lock);
	if (w->dcw_gen == dcl->dcl_gen) {
		dcl->dcl_apply_ready = dcl->dcl_index_active &&
		    avl_numnodes(&dcl->dcl_index) == 0;
	}
	mutex_exit(&dcl->dcl_lock);
	w->dcw_group_src_valid = B_FALSE;
	kmem_free(buf, bufmax * sizeof (*buf));
}

/*
 * Apply one decided candidate.  It goes through the unordered path
 * as a group of one whose source is already chosen, so the yield
 * handshake, the batching and every per-destination check are the
 * same code in both orders.
 */
static void
dsl_clonedup_apply_one(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *w,
    dsl_clonedup_entry_t *e,
    zthr_t *zthr)
{
	dsl_clonedup_entry_t *ep = e;
	dsl_clonedup_group_t g;

	memset(&g, 0, sizeof (g));
	g.g_entries = &ep;
	g.g_count = 1;
	g.g_max = 1;
	g.g_key = e->dce_key;
	g.g_prop = e->dce_prop;
	g.g_src = e->dce_src;
	g.g_counted = B_TRUE;

	w->dcw_group_src_valid = B_FALSE;
	dsl_clonedup_group_process(dcl, w, &g, zthr);
	w->dcw_group_src_valid = B_FALSE;

	kmem_free(e->dce_src, sizeof (*e->dce_src));
	kmem_cache_free(dsl_clonedup_entry_cache, e);
}

/*
 * Does another worker hold this dataset?  An unmounted destination is
 * taken with dmu_objset_own(), which is exclusive, so two workers on
 * one dataset would collide.  The apply tree sorts on the destination
 * dataset first, so skipping a claimed one lands the worker on the
 * next dataset rather than interleaving.
 */
static boolean_t
dsl_clonedup_ds_taken(dsl_clonedup_t *dcl, dsl_clonedup_worker_t *me,
    uint64_t dsobj)
{
	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	for (uint_t i = 0; i < dcl->dcl_nworkers; i++) {
		dsl_clonedup_worker_t *o = dcl->dcl_workers[i];

		if (o == NULL || o == me)
			continue;
		if (o->dcw_claim_dst == dsobj)
			return (B_TRUE);
	}
	return (B_FALSE);
}

/*
 * The first entry of the dataset after dsobj.  The tree sorts on the
 * destination dataset, so one descent skips every entry of a dataset
 * another worker holds.  Stepping them one at a time is quadratic in
 * the candidate count and runs under dcl_lock.
 */
static dsl_clonedup_entry_t *
dsl_clonedup_apply_next_ds(dsl_clonedup_t *dcl, uint64_t dsobj)
{
	dsl_clonedup_entry_t probe;
	dsl_clonedup_src_t psrc;
	avl_index_t where;
	dsl_clonedup_entry_t *e;

	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	if (dsobj == UINT64_MAX)
		return (NULL);
	memset(&probe, 0, sizeof (probe));
	memset(&psrc, 0, sizeof (psrc));
	probe.dce_src = &psrc;
	probe.dce_objset = dsobj + 1;
	e = avl_find(&dcl->dcl_apply, &probe, &where);
	if (e == NULL)
		e = avl_nearest(&dcl->dcl_apply, where, AVL_AFTER);
	return (e);
}

static dsl_clonedup_entry_t *
dsl_clonedup_apply_pop(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, boolean_t *taken)
{
	dsl_clonedup_entry_t *e;

	ASSERT(MUTEX_HELD(&dcl->dcl_lock));
	*taken = B_FALSE;
	e = avl_first(&dcl->dcl_apply);
	while (e != NULL) {
		if (!dsl_clonedup_ds_taken(dcl, w, e->dce_objset)) {
			avl_remove(&dcl->dcl_apply, e);
			dcl->dcl_nentries--;
			dcl->dcl_nsrc--;
			dcl->dcl_mem_used -= sizeof (*e) +
			    sizeof (*e->dce_src);
			w->dcw_claim_dst = e->dce_objset;
			return (e);
		}
		*taken = B_TRUE;
		e = dsl_clonedup_apply_next_ds(dcl, e->dce_objset);
	}
	w->dcw_claim_dst = 0;
	return (NULL);
}

static void
dsl_clonedup_apply_idle(dsl_clonedup_t *dcl, boolean_t *busyp)
{
	if (!*busyp)
		return;
	mutex_enter(&dcl->dcl_lock);
	if (dcl->dcl_apply_busy > 0)
		dcl->dcl_apply_busy--;
	mutex_exit(&dcl->dcl_lock);
	*busyp = B_FALSE;
}

static void
dsl_clonedup_apply_ordered(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, zthr_t *zthr)
{
	dsl_pool_t *dp = dcl->dcl_dp;
	spa_t *spa = dp->dp_spa;
	dsl_clonedup_entry_t *e;
	boolean_t busy = B_FALSE, last, taken;

	while (!dsl_clonedup_stop(dcl, zthr)) {
		if (dsl_scan_is_paused_scrub(dp->dp_scan) ||
		    !zfs_clonedup_apply_enabled)
			break;
		dsl_clonedup_yield_release(dcl, w);
		mutex_enter(&dcl->dcl_lock);
		e = NULL;
		taken = B_FALSE;
		if (dcl->dcl_index_active &&
		    w->dcw_gen == dcl->dcl_gen)
			e = dsl_clonedup_apply_pop(dcl, w, &taken);
		if (e == NULL) {
			mutex_exit(&dcl->dcl_lock);
			if (!taken)
				break;
			/*
			 * Only datasets another worker owns are left.
			 * Give up what this one holds so it is not
			 * the one they wait on, and look again.
			 */
			dsl_clonedup_batch_flush(dcl, w);
			dsl_clonedup_apply_idle(dcl, &busy);
			dsl_clonedup_dst_rele(dcl, w);
			delay(1);
			continue;
		}
		if (!busy)
			dcl->dcl_apply_busy++;
		busy = B_TRUE;
		mutex_exit(&dcl->dcl_lock);

		dsl_clonedup_apply_one(dcl, w, e, zthr);

		mutex_enter(&dcl->dcl_lock);
		last = w->dcw_gen != dcl->dcl_gen ||
		    avl_numnodes(&dcl->dcl_apply) == 0;
		mutex_exit(&dcl->dcl_lock);
		if (last || vdev_queue_pool_busy(spa))
			dsl_clonedup_batch_flush(dcl, w);
		if (w->dcw_batch.dcb_count == 0)
			dsl_clonedup_apply_idle(dcl, &busy);
	}
	if (zfs_clonedup_apply_flush_delay != 0 &&
	    w->dcw_batch.dcb_count > 0)
		delay(MSEC_TO_TICK(zfs_clonedup_apply_flush_delay));
	dsl_clonedup_batch_flush(dcl, w);
	dsl_clonedup_apply_idle(dcl, &busy);
	mutex_enter(&dcl->dcl_lock);
	w->dcw_claim_dst = 0;
	mutex_exit(&dcl->dcl_lock);
}

boolean_t
dsl_clonedup_apply_check(void *arg, zthr_t *zthr)
{
	(void) zthr;
	spa_t *spa = arg;
	dsl_pool_t *dp = spa_get_dsl(spa);
	dsl_clonedup_t *dcl;
	boolean_t work;

	if (dp == NULL || (dcl = dp->dp_clonedup) == NULL)
		return (B_FALSE);
	if (!zfs_clonedup_apply_enabled || !spa_writeable(spa) ||
	    spa_shutting_down(spa) ||
	    spa_load_state(spa) != SPA_LOAD_NONE)
		return (B_FALSE);
	if (dsl_scan_is_paused_scrub(dp->dp_scan))
		return (B_FALSE);

	mutex_enter(&dcl->dcl_lock);
	work = dcl->dcl_phys.dclp_state == DSS_SCANNING &&
	    dcl->dcl_phys.dclp_phase == POOL_CLONEDUP_APPLY &&
	    dcl->dcl_index_active && dcl->dcl_nentries > 0;
	mutex_exit(&dcl->dcl_lock);
	return (work);
}

typedef struct dsl_clonedup_wtask {
	dsl_clonedup_t		*wt_dcl;
	dsl_clonedup_worker_t	*wt_w;
	zthr_t			*wt_zthr;
} dsl_clonedup_wtask_t;

static uint_t
dsl_clonedup_worker_count(void)
{
	uint_t n = zfs_clonedup_apply_threads;

	if (n == 0)
		n = MAX(1, (max_ncpus + 3) / 4);
	return (MIN(MAX(1, n), DCL_MAX_WORKERS));
}

static void
dsl_clonedup_worker_run(void *arg)
{
	dsl_clonedup_wtask_t *wt = arg;
	dsl_clonedup_t *dcl = wt->wt_dcl;
	dsl_clonedup_worker_t *w = wt->wt_w;

	dsl_clonedup_batch_init(dcl, w);
	dsl_clonedup_dscache_init(w);
	dsl_clonedup_apply_ordered(dcl, w, wt->wt_zthr);
	dsl_clonedup_batch_flush(dcl, w);
	dsl_clonedup_dscache_fini(w);
	dsl_clonedup_batch_fini(dcl, w);
	dsl_clonedup_dst_rele(dcl, w);
	dsl_clonedup_src_rele(dcl, w);
	mutex_enter(&dcl->dcl_lock);
	dcl->dcl_apply_running--;
	cv_broadcast(&dcl->dcl_apply_cv);
	mutex_exit(&dcl->dcl_lock);
}

/*
 * Run the apply on several workers.  The caller's worker is one of
 * them and runs here, so a single worker costs no taskq at all.
 */
static void
dsl_clonedup_apply_parallel(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w,
    zthr_t *zthr)
{
	uint_t n = dsl_clonedup_worker_count(), i;
	dsl_clonedup_wtask_t *wt = NULL;
	taskq_t *tq = NULL;

	dcl->dcl_workers[0] = w;
	for (i = 1; i < n; i++) {
		dcl->dcl_workers[i] = kmem_zalloc(sizeof (*w),
		    KM_SLEEP);
		dcl->dcl_workers[i]->dcw_gen = w->dcw_gen;
	}
	dcl->dcl_nworkers = n;

	if (n > 1) {
		tq = taskq_create("clonedup_apply", n - 1,
		    minclsyspri, n - 1, n - 1, TASKQ_PREPOPULATE);
		wt = kmem_zalloc((n - 1) * sizeof (*wt), KM_SLEEP);
		mutex_enter(&dcl->dcl_lock);
		dcl->dcl_apply_running = n - 1;
		mutex_exit(&dcl->dcl_lock);
		for (i = 1; i < n; i++) {
			wt[i - 1].wt_dcl = dcl;
			wt[i - 1].wt_w = dcl->dcl_workers[i];
			wt[i - 1].wt_zthr = zthr;
			VERIFY(taskq_dispatch(tq,
			    dsl_clonedup_worker_run, &wt[i - 1],
			    TQ_SLEEP) != TASKQID_INVALID);
		}
	}

	dsl_clonedup_apply_ordered(dcl, w, zthr);

	if (tq != NULL) {
		/*
		 * A worker still running may be waiting for the
		 * dataset this thread holds, and nothing would
		 * release it until after the wait.
		 */
		dsl_clonedup_batch_flush(dcl, w);
		dsl_clonedup_dst_rele(dcl, w);
		dsl_clonedup_src_rele(dcl, w);
		for (;;) {
			(void) dsl_clonedup_stop(dcl, zthr);
			mutex_enter(&dcl->dcl_lock);
			if (dcl->dcl_apply_running == 0) {
				mutex_exit(&dcl->dcl_lock);
				break;
			}
			(void) cv_timedwait(&dcl->dcl_apply_cv,
			    &dcl->dcl_lock,
			    ddi_get_lbolt() + MSEC_TO_TICK(100));
			mutex_exit(&dcl->dcl_lock);
		}
		taskq_wait(tq);
		taskq_destroy(tq);
		kmem_free(wt, (n - 1) * sizeof (*wt));
	}
	/*
	 * Drop the count first, then the pointers.  A yield reads
	 * this array without dcl_lock, so freeing a worker it can
	 * still reach would hand it a dangling pointer.
	 */
	dcl->dcl_nworkers = 1;
	for (i = 1; i < n; i++) {
		dsl_clonedup_worker_t *o = dcl->dcl_workers[i];

		dcl->dcl_workers[i] = NULL;
		kmem_free(o, sizeof (*w));
	}
}

static void
dsl_clonedup_apply_groups(dsl_clonedup_t *dcl,
    dsl_clonedup_worker_t *w, zthr_t *zthr)
{
	dsl_pool_t *dp = dcl->dcl_dp;
	spa_t *spa = dp->dp_spa;
	dsl_clonedup_group_t g;
	boolean_t last;

	dsl_clonedup_batch_init(dcl, w);
	dsl_clonedup_dscache_init(w);
	if (zfs_clonedup_apply_order != 0) {
		if (!dcl->dcl_apply_ready)
			dsl_clonedup_order_index(dcl, w, zthr);
		dsl_clonedup_apply_parallel(dcl, w, zthr);
		goto done;
	}
	while (!dsl_clonedup_stop(dcl, zthr)) {
		if (dsl_scan_is_paused_scrub(dp->dp_scan) ||
		    !zfs_clonedup_apply_enabled)
			break;
		dsl_clonedup_yield_release(dcl, w);
		if (!dsl_clonedup_group_take(dcl, w, &g, NULL))
			break;
		dsl_clonedup_group_process(dcl, w, &g, zthr);
		dsl_clonedup_group_free(&g);
		mutex_enter(&dcl->dcl_lock);
		last = dcl->dcl_nentries == 0;
		mutex_exit(&dcl->dcl_lock);
		if (last || vdev_queue_pool_busy(spa))
			dsl_clonedup_batch_flush(dcl, w);
		mutex_enter(&dcl->dcl_lock);
		if (dcl->dcl_apply_busy > 0)
			dcl->dcl_apply_busy--;
		mutex_exit(&dcl->dcl_lock);
	}
done:
	dsl_clonedup_batch_flush(dcl, w);
	dsl_clonedup_dscache_fini(w);
	dsl_clonedup_batch_fini(dcl, w);
	dsl_clonedup_dst_rele(dcl, w);
	dsl_clonedup_src_rele(dcl, w);
}

void
dsl_clonedup_apply_thread(void *arg, zthr_t *zthr)
{
	spa_t *spa = arg;
	dsl_pool_t *dp = spa_get_dsl(spa);
	dsl_clonedup_t *dcl = dp->dp_clonedup;

	mutex_enter(&dcl->dcl_lock);
	if (!dcl->dcl_index_active ||
	    dcl->dcl_phys.dclp_phase != POOL_CLONEDUP_APPLY) {
		mutex_exit(&dcl->dcl_lock);
		return;
	}
	dcl->dcl_w.dcw_gen = dcl->dcl_gen;
	dcl->dcl_w.dcw_group_src_valid = B_FALSE;
	dcl->dcl_zthr = zthr;
	dcl->dcl_apply_stop = B_FALSE;
	mutex_exit(&dcl->dcl_lock);
	dsl_clonedup_apply_groups(dcl, &dcl->dcl_w, zthr);
	mutex_enter(&dcl->dcl_lock);
	dcl->dcl_zthr = NULL;
	mutex_exit(&dcl->dcl_lock);
}

void
dsl_clonedup_apply_wakeup(spa_t *spa)
{
	if (spa->spa_clonedup_apply_zthr != NULL)
		zthr_wakeup(spa->spa_clonedup_apply_zthr);
}

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, scan_mem_lim_fact,
	UINT, ZMOD_RW,
	"Divisor of RAM for the clonedup index, 0 to follow scrub");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, scan_mem_max, U64,
	ZMOD_RW,
	"Bytes the clonedup index may use (0 = RAM / lim_fact)");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, scan_weak_checksums,
	INT, ZMOD_RW,
	"Index blocks with weak checksums (always verified)");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, scan_noapply, INT,
	ZMOD_RW, "Debug: drop the clonedup index instead of cloning");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_enabled, INT,
	ZMOD_RW, "Run the clonedup apply thread");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_trust_checksum,
	INT, ZMOD_RW,
	"Clone on equal dedup-grade checksums, no read");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_snapheld, INT,
	ZMOD_RW, "Redirect head blocks that a snapshot also holds");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_zero_blocks, INT,
	ZMOD_RW, "All-zero blocks: 0 punch a hole, 1 clone, 2 skip");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_order, UINT,
	ZMOD_RW,
	"Apply order: 0 checksum, 1 source block, 2 destination");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_threads, UINT,
	ZMOD_RW, "Apply workers, 0 for one per four cores");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_blocks_per_txg,
	UINT, ZMOD_RW,
	"Most blocks the apply workers put in one txg");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_skip_src_wait,
	INT, ZMOD_RW, "Debug: skip the wait for the previous txg");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_txg_delay, UINT,
	ZMOD_RW, "Debug: ms to sleep between verifying and cloning");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_flush_delay, UINT,
	ZMOD_RW, "Debug: ms to sleep before a worker's final flush");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, apply_commit_delay,
	UINT, ZMOD_RW,
	"Debug: ms to hold a batch's transaction open");

ZFS_MODULE_PARAM(zfs_clonedup, zfs_clonedup_, yield_timeout_ms, UINT,
	ZMOD_RW, "ms an admin operation waits for the apply thread");
