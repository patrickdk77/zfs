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

#ifndef	_SYS_DSL_CLONEDUP_H
#define	_SYS_DSL_CLONEDUP_H

#include <sys/zfs_context.h>
#include <sys/avl.h>
#include <sys/dmu.h>
#include <sys/spa.h>
#include <sys/bitops.h>
#include <sys/zthr.h>
#include <sys/wmsum.h>

#ifdef	__cplusplus
extern "C" {
#endif

struct dsl_pool;
struct dnode_phys;

typedef pool_clonedup_phase_t dsl_clonedup_phase_t;

/*
 * Progress of a clonedup run, stored as a uint64 array under
 * DMU_POOL_CLONEDUP_SCAN in the pool directory.  Every member is a
 * uint64_t so the array byteswaps as a whole.  Readers accept a
 * shorter or longer stored array and only use the members they know.
 */
typedef struct dsl_clonedup_phys {
	uint64_t dclp_version;
	uint64_t dclp_state;		/* dsl_scan_state_t */
	uint64_t dclp_flags;		/* DSF_CLONEDUP_* */
	uint64_t dclp_phase;		/* pool_clonedup_phase_t */
	uint64_t dclp_partition_shift;	/* log2 of partition count */
	uint64_t dclp_partition;	/* partition being worked */
	uint64_t dclp_min_txg;
	uint64_t dclp_max_txg;
	uint64_t dclp_start_time;
	uint64_t dclp_end_time;
	/* max_txg of the last complete run */
	uint64_t dclp_last_txg;
	uint64_t dclp_blocks_examined;
	uint64_t dclp_blocks_indexed;
	uint64_t dclp_groups;
	uint64_t dclp_candidates;
	uint64_t dclp_applied;
	uint64_t dclp_bytes_saved;
	uint64_t dclp_bytes_saved_snapheld;
	uint64_t dclp_skipped_stale;
	uint64_t dclp_skipped_dirty;
	uint64_t dclp_skipped_differs;
	uint64_t dclp_skipped_busy;
	uint64_t dclp_skipped_policy;
	uint64_t dclp_errors;
	uint64_t dclp_filter_slots;	/* 0 if no pre-pass ran */
	uint64_t dclp_planned_entries;	/* 2*A + B of the pre-pass */
	uint64_t dclp_filter_seen;	/* blocks the pre-pass saw */
	uint64_t dclp_keep_pct;		/* percent the filter kept */
} dsl_clonedup_phys_t;

#define	DSL_CLONEDUP_PHYS_VERSION	1
#define	DSL_CLONEDUP_PHYS_NUMINTS \
	(sizeof (dsl_clonedup_phys_t) / sizeof (uint64_t))

/*
 * Block properties packed into one word so that entries with equal
 * checksum and equal properties sort next to each other.  Sizes are
 * in SPA_MINBLOCKSHIFT units as in ddt_key_t.
 */
#define	DCE_PROP_GET_LSIZE(p) \
	BF64_GET_SB((p), 0, 16, SPA_MINBLOCKSHIFT, 1)
#define	DCE_PROP_SET_LSIZE(p, x) \
	BF64_SET_SB((p), 0, 16, SPA_MINBLOCKSHIFT, 1, x)
#define	DCE_PROP_GET_PSIZE(p) \
	BF64_GET_SB((p), 16, 16, SPA_MINBLOCKSHIFT, 1)
#define	DCE_PROP_SET_PSIZE(p, x) \
	BF64_SET_SB((p), 16, 16, SPA_MINBLOCKSHIFT, 1, x)
#define	DCE_PROP_GET_COMPRESS(p)	BF64_GET((p), 32, 7)
#define	DCE_PROP_SET_COMPRESS(p, x)	BF64_SET((p), 32, 7, x)
#define	DCE_PROP_GET_BYTEORDER(p)	BF64_GET((p), 40, 1)
#define	DCE_PROP_SET_BYTEORDER(p, x) \
	BF64_SET((p), 40, 1, x)
#define	DCE_PROP_GET_CHECKSUM(p)	BF64_GET((p), 48, 8)
#define	DCE_PROP_SET_CHECKSUM(p, x)	BF64_SET((p), 48, 8, x)

/* dce_flags and dcs_flags */
#define	DCE_F_SNAPHELD		0x01	/* held by a snapshot */
#define	DCE_F_SRCONLY		0x02	/* clonedup=source dataset */
#define	DCE_F_MAYBE_SHARED	0x04	/* brt_maybe_exists() true */
#define	DCE_F_ZVOL		0x08	/* DMU_OT_ZVOL object */

/*
 * A block older than the run's window that matched a group.  It is
 * the preferred clone source for that group and hangs off the group's
 * first entry.
 */
typedef struct dsl_clonedup_src {
	dva_t		dcs_dva;	/* DVA[0] */
	uint64_t	dcs_birth;	/* physical birth */
	uint64_t	dcs_objset;
	uint64_t	dcs_object;
	uint64_t	dcs_blkid;
	uint32_t	dcs_blkszsec;
	uint8_t		dcs_dntype;
	uint8_t		dcs_flags;
	uint16_t	dcs_pad;
} dsl_clonedup_src_t;

/*
 * One block born inside the run's window.  Sorted by key, prop, DVA,
 * birth and locator, so a group of equal-content candidates is a run
 * of adjacent entries.
 */
typedef struct dsl_clonedup_entry {
	avl_node_t	dce_node;
	uint64_t	dce_key;	/* cityhash4 of blk_cksum */
	uint64_t	dce_prop;	/* DCE_PROP_* */
	dva_t		dce_dva;	/* DVA[0] */
	uint64_t	dce_birth;	/* physical birth */
	uint64_t	dce_objset;
	uint64_t	dce_object;
	uint64_t	dce_blkid;
	uint32_t	dce_blkszsec;
	uint8_t		dce_dntype;
	uint8_t		dce_flags;
	uint16_t	dce_pad;
	/*
	 * Group source.  In the index only a group's first entry
	 * holds it; in the apply tree every entry holds its own copy.
	 */
	dsl_clonedup_src_t *dce_src;
} dsl_clonedup_entry_t;

struct zfs_clonedup_dst;
struct dsl_dataset;

/* counters exported as the kstat zfs/<pool>/clonedup */
typedef enum dsl_clonedup_kstat_id {
	DCK_VERIFY_READS,	/* blocks read to verify candidates */
	DCK_VERIFY_BYTES,
	DCK_CLONES,		/* blocks redirected to a survivor */
	DCK_PUNCHED,		/* all-zero blocks turned to holes */
	DCK_YIELDS,		/* yield requests that found a hold */
	DCK_YIELD_WAITS,	/* holds delayed by a yield */
	DCK_INDEX_WALKS,
	DCK_MATCH_WALKS,
	DCK_DST_MOUNTED,	/* destinations opened as files */
	DCK_DST_ZVOL,		/* destinations opened as volumes */
	DCK_DST_OWNED,		/* destinations opened by ownership */
	DCK_BATCHES,		/* transactions carrying clones */
	DCK_KEY_COLLISIONS,	/* key matched, checksum did not */
	DCK_CKSUM_COLLISIONS,	/* checksum matched, data did not */
	DCK_COPIES_MISMATCH,	/* declined: unequal DVA counts */
	DCK_COUNT_WALKS,	/* counting pre-passes run */
	DCK_FILTER_DROPPED,	/* blocks the filter kept out */
	DCK_NUM
} dsl_clonedup_kstat_id_t;

/* where a block lives, for the apply's debug lines */
typedef struct dsl_clonedup_loc {
	uint64_t	l_objset;
	uint64_t	l_object;
	uint64_t	l_blkid;
} dsl_clonedup_loc_t;

/* one destination block waiting for its batch transaction */
typedef struct dsl_clonedup_pend {
	struct zfs_clonedup_dst *dcp_dst;
	void		*dcp_lock;	/* range lock, or NULL */
	uint64_t	dcp_blkid;
	uint64_t	dcp_blksz;
	uint64_t	dcp_sobject;
	uint64_t	dcp_sblkid;
	blkptr_t	dcp_sbp;
	uint64_t	dcp_dasize;
	uint64_t	dcp_dobject;
	blkptr_t	dcp_dbp;
	struct abd	*dcp_sabd;	/* source, one per group */
	struct abd	*dcp_dabd;
	int		dcp_serr;
	int		dcp_derr;
	boolean_t	dcp_sowner;	/* issued the source read */
	boolean_t	dcp_snapheld;
	boolean_t	dcp_punch;
	boolean_t	dcp_trusted;	/* checksums prove equality */
	boolean_t	dcp_drop;	/* did not verify */
	boolean_t	dcp_src_punch;	/* punch the source if zero */
} dsl_clonedup_pend_t;

/*
 * Clones waiting on one transaction.  A batch stays within one
 * destination dataset and one source dataset, so the pair the yield
 * handshake publishes cannot change while it is open, and the whole
 * batch costs one previous-txg wait instead of one per block.
 */
typedef struct dsl_clonedup_batch {
	uint64_t	dcb_dsobj;	/* destination dataset */
	uint64_t	dcb_srcobj;	/* source dataset */
	objset_t	*dcb_os;	/* destination objset */
	objset_t	*dcb_sos;	/* source objset */
	boolean_t	dcb_src_stable;	/* source cannot change */
	boolean_t	dcb_dryrun;	/* count, never clone */
	uint_t		dcb_count;
	uint_t		dcb_ndst;	/* handles to close */
	uint_t		dcb_max;
	dsl_clonedup_pend_t *dcb_pend;
	struct zfs_clonedup_dst **dcb_dsts;
	uint64_t	*dcb_dstobj;	/* object of each handle */
	uint32_t	*dcb_dsthash;	/* bucket to slot + 1 */
	uint32_t	*dcb_dstnext;	/* slot to next slot + 1 */
	uint_t		dcb_dstmask;	/* buckets - 1 */
} dsl_clonedup_batch_t;

#define	DCL_MAX_WORKERS	64

typedef struct dsl_clonedup_worker {
	dsl_clonedup_batch_t dcw_batch;
	struct zfs_clonedup_dst *dcw_dst; /* cached destination */
	uint64_t	dcw_dst_objset;
	uint64_t	dcw_dst_object;
	struct dsl_dataset *dcw_src_ds; /* cached source dataset */
	objset_t	*dcw_src_os;
	uint64_t	dcw_src_objset;
	/* source for a split group */
	boolean_t	dcw_group_src_valid;
	uint64_t	dcw_group_key;
	uint64_t	dcw_group_prop;
	dsl_clonedup_src_t dcw_group_src;
	uint64_t	dcw_held_src;	/* dataset held, or being */
	uint64_t	dcw_held_dst;	/* acquired, by this worker */
	uint64_t	dcw_claim_dst;	/* claimed dataset */
	avl_tree_t	dcw_dscache;	/* per-dataset answers */
	uint64_t	dcw_dscache_txg;
	boolean_t	dcw_dscache_ready;
	uint64_t	dcw_gen;	/* dcl_gen it serves */
} dsl_clonedup_worker_t;

/*
 * Counting pre-pass.  Two bits a slot, four slots a byte, indexed by
 * the block key: never seen, seen once, seen twice or more.  A key
 * that never repeats cannot pair with anything, so phase 1 declines
 * to store an entry for it.
 *
 * A slot is shared by unrelated keys.  That reports a block as
 * repeated when it is not, which costs one index entry, the cost of
 * every block without the filter.  It never reports a repeated key
 * as unique, so nothing that could pair is lost.
 *
 * dcf_once counts slots that went from one to two and dcf_extra
 * counts blocks that landed on a slot already at two, so
 * 2 * dcf_once + dcf_extra is exactly how many entries phase 1 will
 * store.  That is known before the index is allocated.
 */
typedef struct dsl_clonedup_filter {
	uint8_t		*dcf_bits;
	uint64_t	dcf_slots;	/* power of two */
	uint64_t	dcf_bytes;
	uint64_t	dcf_once;	/* A: slots at two */
	uint64_t	dcf_extra;	/* B: blocks past two */
	uint64_t	dcf_seen;	/* blocks offered */
} dsl_clonedup_filter_t;

typedef struct dsl_clonedup {
	struct dsl_pool	*dcl_dp;
	kmutex_t	dcl_lock;
	dsl_clonedup_phys_t dcl_phys;
	dsl_clonedup_phys_t dcl_phys_written;	/* the copy on disk */
	boolean_t	dcl_index_active;
	uint64_t	dcl_gen;	/* bumped by index_destroy */
	uint_t		dcl_apply_busy;	/* workers holding work */
	avl_tree_t	dcl_index;
	uint64_t	dcl_nentries;
	uint64_t	dcl_apply_total;
	uint64_t	dcl_nsrc;
	uint64_t	dcl_mem_used;
	uint64_t	dcl_mem_max;
	uint64_t	dcl_splits;
	dsl_clonedup_filter_t *dcl_filter;

	/*
	 * What one apply worker holds while it works: its batch, the
	 * handles it has open and the source it picked for a split
	 * group.  These belong to the worker, not the run, so more
	 * than one worker can apply at once.
	 */
	dsl_clonedup_worker_t dcl_w;
	/*
	 * Live apply workers.  A fixed array, so a reader never races
	 * a reallocation.  An entry is set before its worker starts
	 * and cleared after every worker has stopped, so a stale read
	 * sees a finished worker whose held slots are already zero.
	 */
	dsl_clonedup_worker_t *dcl_workers[DCL_MAX_WORKERS];
	uint_t		dcl_nworkers;

	/* apply state the workers share, written under dcl_lock */
	uint64_t	dcl_apply_txg;	/* newest txg counted */
	uint64_t	dcl_apply_in_txg; /* blocks counted in it */
	avl_tree_t	dcl_apply;	/* entries in apply order */
	boolean_t	dcl_apply_ready; /* order pass has run */
	/* the group the order pass is on, see order_index() */
	uint64_t	dcl_order_key;
	uint64_t	dcl_order_prop;
	boolean_t	dcl_order_have;
	boolean_t	dcl_order_counted;
	struct zthr	*dcl_zthr;
	boolean_t	dcl_apply_stop;	/* the zthr saw its cancel */
	uint_t		dcl_apply_running; /* live taskq workers */
	kcondvar_t	dcl_apply_cv;	/* one of them has finished */

	/* yield handshake, see dsl_clonedup_yield_begin() */
	kmutex_t	dcl_yield_lock;
	kcondvar_t	dcl_yield_cv;
	uint_t		dcl_yield_pause; /* operations in progress */

	kstat_t		*dcl_ksp;
	kstat_named_t	dcl_kstat[DCK_NUM];
	wmsum_t		dcl_wsums[DCK_NUM];
	uint32_t	dcl_dbg_left;	/* dbgmsg lines left in run */
} dsl_clonedup_t;

/* outcome of one destination block */
typedef enum zfs_clonedup_result {
	ZCR_APPLIED,
	ZCR_ALREADY_SHARED,
	ZCR_SRC_STALE,
	ZCR_SRC_DIRTY,
	ZCR_DST_STALE,
	ZCR_DST_DIRTY,
	ZCR_ERROR,
	ZCR_QUEUED,
} zfs_clonedup_result_t;

/*
 * Destination side of the apply, implemented in zfs_clonedup_apply.c
 * (kernel only; libzpool stubs return ENOTSUP).  A handle is a file
 * in a mounted filesystem, a block device of an open volume, or an
 * object of a dataset the apply thread owns.
 */
typedef struct zfs_clonedup_dst zfs_clonedup_dst_t;
int zfs_clonedup_dst_open(spa_t *spa, uint64_t dsobj, uint64_t object,
    zfs_clonedup_dst_t **dstp);
void zfs_clonedup_dst_close(zfs_clonedup_dst_t *dst);
objset_t *zfs_clonedup_dst_objset(zfs_clonedup_dst_t *dst);
uint64_t zfs_clonedup_dst_object(zfs_clonedup_dst_t *dst);
boolean_t zfs_clonedup_dst_exclusive(zfs_clonedup_dst_t *dst);
dsl_clonedup_kstat_id_t zfs_clonedup_dst_kind(
    zfs_clonedup_dst_t *dst);
int zfs_clonedup_dst_prepare(zfs_clonedup_dst_t *dst, uint64_t blkid,
    const blkptr_t *dexp, objset_t *sos, boolean_t nowait,
    boolean_t *readyp, void **lockp, zfs_clonedup_result_t *resp);
void zfs_clonedup_dst_tx_hold(dmu_tx_t *tx, zfs_clonedup_dst_t *dst,
    uint64_t blkid, uint64_t blksz, boolean_t punch);
int zfs_clonedup_src_validate(objset_t *sos, uint64_t sobj,
    uint64_t sblkid, const blkptr_t *sexp, blkptr_t *bp,
    zfs_clonedup_result_t *resp);
int zfs_clonedup_dst_finish(zfs_clonedup_dst_t *dst, uint64_t blkid,
    uint64_t blksz, objset_t *sos, uint64_t sobj, uint64_t sblkid,
    const blkptr_t *sexp, const blkptr_t *sval, boolean_t punch,
    dmu_tx_t *tx, zfs_clonedup_result_t *resp);
void zfs_clonedup_dst_unlock(void *lock);
int zfs_clonedup_dst_apply(zfs_clonedup_dst_t *dst, uint64_t blkid,
    const blkptr_t *dexp, objset_t *sos, uint64_t sobj,
    uint64_t sblkid, const blkptr_t *sexp, boolean_t punch,
    zfs_clonedup_result_t *resp);

/* what dsl_scan_sync() should do after a phase completes */
typedef enum dsl_clonedup_next {
	DCLN_WALK,	/* start another walk from *min_txgp */
	DCLN_APPLY,	/* hand the index to the apply thread */
	DCLN_FINISH,	/* the run is complete */
} dsl_clonedup_next_t;

void dsl_clonedup_global_init(void);
void dsl_clonedup_global_fini(void);
int dsl_clonedup_init(struct dsl_pool *dp);
void dsl_clonedup_fini(struct dsl_pool *dp);
uint64_t dsl_clonedup_last_txg(struct dsl_pool *dp);
void dsl_clonedup_sync_state(dsl_clonedup_t *dcl, dmu_tx_t *tx);

void dsl_clonedup_run_setup(dsl_clonedup_t *dcl, uint64_t flags,
    uint64_t min_txg, uint64_t max_txg, boolean_t restart,
    dmu_tx_t *tx);
void dsl_clonedup_run_done(dsl_clonedup_t *dcl, boolean_t complete,
    dmu_tx_t *tx);
boolean_t dsl_clonedup_bp_eligible(spa_t *spa, const blkptr_t *bp,
    const struct dnode_phys *dnp, const zbookmark_phys_t *zb);
void dsl_clonedup_visit(dsl_clonedup_t *dcl, const blkptr_t *bp,
    const zbookmark_phys_t *zb, const struct dnode_phys *dnp,
    uint8_t flags);
dsl_clonedup_next_t dsl_clonedup_walk_done(dsl_clonedup_t *dcl,
    uint64_t *min_txgp, dmu_tx_t *tx);
boolean_t dsl_clonedup_apply_done(dsl_clonedup_t *dcl);
boolean_t dsl_clonedup_apply_paced(dmu_tx_t *tx, uint_t n);
boolean_t dsl_clonedup_bp_same_block(const blkptr_t *a,
    const blkptr_t *b);
boolean_t dsl_clonedup_apply_check(void *arg, struct zthr *zthr);
void dsl_clonedup_apply_thread(void *arg, struct zthr *zthr);
void dsl_clonedup_apply_wakeup(spa_t *spa);
dsl_clonedup_next_t dsl_clonedup_partition_done(dsl_clonedup_t *dcl,
    uint64_t *min_txgp, dmu_tx_t *tx);
void dsl_clonedup_yield_begin(spa_t *spa);
void dsl_clonedup_yield_end(spa_t *spa);
void dsl_clonedup_yield_begin_name(const char *name);
void dsl_clonedup_yield_end_name(const char *name);

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_DSL_CLONEDUP_H */
