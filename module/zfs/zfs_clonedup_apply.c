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
 * Destination side of "zpool clonedup".  A destination is one object
 * in one dataset, reached one of three ways: a file in a mounted
 * filesystem through its znode, a block of an open volume through
 * its zvol_state_t, or any object of a dataset nobody else has open
 * by owning the dataset.  The first two exclude concurrent writers
 * with the object's range lock; ownership excludes them outright,
 * since mount, volume open and receive all need ownership too.
 * Everything that needs a znode or a zvol_state_t lives here;
 * dsl_clonedup.c stays at the DMU level.
 */

#include <sys/stat.h>
#include <sys/dsl_clonedup.h>
#include <sys/dsl_pool.h>
#include <sys/dsl_dataset.h>
#include <sys/dsl_prop.h>
#include <sys/dmu.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_tx.h>
#include <sys/dbuf.h>
#include <sys/dnode.h>
#include <sys/sa.h>
#include <sys/txg.h>
#include <sys/zil.h>
#include <sys/zfs_znode.h>
#include <sys/zfs_vfsops.h>
#include <sys/zfs_ioctl.h>
#include <sys/zfs_ioctl_impl.h>
#include <sys/zfs_rlock.h>
#include <sys/zfs_quota.h>
#include <sys/zfs_vnops.h>
#include <sys/zvol.h>
#include <sys/zvol_impl.h>

struct zfs_clonedup_dst {
	uint64_t	zcd_object;
	zfsvfs_t	*zcd_zfsvfs;	/* file: zfs_vfs_ref() pin */
	znode_t		*zcd_zp;
	zvol_state_t	*zcd_zv;	/* volume: one open count */
	objset_t	*zcd_os;	/* owned dataset */
	dnode_t		*zcd_dn;	/* owned: the object */
	boolean_t	zcd_borrowed;	/* the caller owns zcd_os */
};

/* zfs_enter() and zfs_exit() must see the same tag */
static char zfs_clonedup_tag;

/*
 * Hold the dataset just long enough to learn its type and, for a
 * volume, its name.  Snapshots are never destinations.
 */
static int
zfs_clonedup_dst_lookup(dsl_pool_t *dp, uint64_t dsobj,
    dmu_objset_type_t *typep, char *name)
{
	dsl_dataset_t *ds;
	objset_t *os = NULL;
	int err;

	dsl_pool_config_enter(dp, FTAG);
	err = dsl_dataset_hold_obj(dp, dsobj, FTAG, &ds);
	if (err == 0) {
		if (ds->ds_is_snapshot)
			err = SET_ERROR(EBUSY);
		else
			err = dmu_objset_from_ds(ds, &os);
		if (err == 0) {
			*typep = dmu_objset_type(os);
			dsl_dataset_name(ds, name);
		}
		dsl_dataset_rele(ds, FTAG);
	}
	dsl_pool_config_exit(dp, FTAG);
	return (err);
}

/*
 * getzfsvfs_impl() with a reference that never sleeps: an unmount in
 * progress takes os_user_ptr_lock after its vfs_busy() holders have
 * drained, and on FreeBSD a plain vfs_busy() waits for the unmount.
 */
static int
zfs_clonedup_vfs_hold(objset_t *os, zfsvfs_t **zfvp)
{
	int err;

	if (dmu_objset_type(os) != DMU_OST_ZFS)
		return (SET_ERROR(EINVAL));
	mutex_enter(&os->os_user_ptr_lock);
	*zfvp = dmu_objset_get_user(os);
	err = zfs_vfs_ref_nowait(zfvp);
	mutex_exit(&os->os_user_ptr_lock);
	return (err);
}

/*
 * A mounted filesystem is pinned through its zfsvfs, then the file is
 * held as a znode.  EBUSY means not mounted or on its way out.
 */
static int
zfs_clonedup_file_open(spa_t *spa, uint64_t dsobj, uint64_t object,
    zfs_clonedup_dst_t **dstp)
{
	dsl_pool_t *dp = spa_get_dsl(spa);
	dsl_dataset_t *ds;
	objset_t *os = NULL;
	zfsvfs_t *zfsvfs = NULL;
	znode_t *zp;
	zfs_clonedup_dst_t *dst;
	int err;

	dsl_pool_config_enter(dp, FTAG);
	err = dsl_dataset_hold_obj(dp, dsobj, FTAG, &ds);
	if (err == 0) {
		err = dmu_objset_from_ds(ds, &os);
		if (err == 0)
			err = zfs_clonedup_vfs_hold(os, &zfsvfs);
		dsl_dataset_rele(ds, FTAG);
	}
	dsl_pool_config_exit(dp, FTAG);

	if (err == ESRCH || err == EINVAL)
		err = SET_ERROR(EBUSY);
	if (err != 0)
		return (err);

	/* From here the pin keeps the zfsvfs and objset alive. */
	if (zfs_enter(zfsvfs, &zfs_clonedup_tag) != 0) {
		zfs_vfs_rele(zfsvfs);
		return (SET_ERROR(EBUSY));
	}
	if (zfs_is_readonly(zfsvfs)) {
		err = SET_ERROR(EROFS);
		goto fail;
	}
	if (zfs_zget(zfsvfs, object, &zp) != 0) {
		err = SET_ERROR(ENOENT);
		goto fail;
	}
	if (zfs_verify_zp(zp) != 0 || !S_ISREG(zp->z_mode) ||
	    zp->z_unlinked) {
		zrele(zp);
		err = SET_ERROR(ENOENT);
		goto fail;
	}
	if (zp->z_pflags & ZFS_IMMUTABLE) {
		zfs_dbgmsg("clonedup: %s object %llu is immutable: "
		    "pflags %llx mode %o", spa_name(spa),
		    (u_longlong_t)object, (u_longlong_t)zp->z_pflags,
		    (uint_t)zp->z_mode);
		zrele(zp);
		err = SET_ERROR(EPERM);
		goto fail;
	}

	dst = kmem_zalloc(sizeof (*dst), KM_SLEEP);
	dst->zcd_object = object;
	dst->zcd_zfsvfs = zfsvfs;
	dst->zcd_zp = zp;
	*dstp = dst;
	return (0);

fail:
	zfs_exit(zfsvfs, &zfs_clonedup_tag);
	zfs_vfs_rele(zfsvfs);
	return (err);
}

/*
 * An open volume is held the way a block device opener holds it: one
 * count in zv_open_count under zv_state_lock, with zv_suspend_lock as
 * reader for as long as the count is ours.  The count is what keeps
 * zv_objset and zv_dn alive; a last close by the real opener would
 * otherwise disown the objset under us.  A closed volume, or one
 * without a minor, is EBUSY here and is written through ownership.
 */
static int
zfs_clonedup_zvol_open(const char *name, uint64_t object,
    zfs_clonedup_dst_t **dstp)
{
	zvol_state_t *zv;
	zfs_clonedup_dst_t *dst;
	int err = 0;

	if (object != ZVOL_OBJ)
		return (SET_ERROR(ENOENT));

	zv = zvol_find_by_name_hash(name, zvol_name_hash(name),
	    RW_READER);
	if (zv == NULL)
		return (SET_ERROR(EBUSY));

	if (zv->zv_open_count == 0 ||
	    (zv->zv_flags & (ZVOL_REMOVING | ZVOL_EXCL)) != 0)
		err = SET_ERROR(EBUSY);
	else if (zv->zv_flags & ZVOL_RDONLY)
		err = SET_ERROR(EROFS);
	else
		zv->zv_open_count++;
	mutex_exit(&zv->zv_state_lock);
	if (err != 0) {
		rw_exit(&zv->zv_suspend_lock);
		return (err);
	}

	dst = kmem_zalloc(sizeof (*dst), KM_SLEEP);
	dst->zcd_object = object;
	dst->zcd_zv = zv;
	*dstp = dst;
	return (0);
}

/* The mirror of zvol_release(): the last count out shuts the zvol. */
static void
zfs_clonedup_zvol_close(zvol_state_t *zv)
{
	ASSERT(RW_READ_HELD(&zv->zv_suspend_lock));

	mutex_enter(&zv->zv_state_lock);
	ASSERT3U(zv->zv_open_count, >, 0);
	zv->zv_open_count--;
	if (zv->zv_open_count == 0)
		zvol_last_close(zv);
	mutex_exit(&zv->zv_state_lock);
	rw_exit(&zv->zv_suspend_lock);
}

/*
 * A dataset nobody has mounted or open is owned for the duration of
 * the hold.  Ownership is what a mount, a volume open and a receive
 * take, so no writer can appear and no range lock is needed.  EBUSY
 * means somebody owns it already, or its log has not been replayed
 * yet and the blocks on disk are not the final content.
 */
static int
zfs_clonedup_own_open(spa_t *spa, uint64_t dsobj, uint64_t object,
    dmu_objset_type_t type, zfs_clonedup_dst_t **dstp)
{
	dsl_pool_t *dp = spa_get_dsl(spa);
	objset_t *os = NULL;
	dnode_t *dn = NULL;
	dmu_object_info_t doi;
	zfs_clonedup_dst_t *dst;
	uint64_t ro = 1;
	int err;

	dsl_pool_config_enter(dp, FTAG);
	err = dmu_objset_own_obj(dp, dsobj, type, B_FALSE, B_FALSE,
	    &zfs_clonedup_tag, &os);
	if (err == 0) {
		(void) dsl_prop_get_int_ds(dmu_objset_ds(os),
		    zfs_prop_to_name(ZFS_PROP_READONLY), &ro);
	}
	dsl_pool_config_exit(dp, FTAG);
	if (err != 0)
		return (err);

	if (os->os_zil_header.zh_flags & ZIL_REPLAY_NEEDED) {
		err = SET_ERROR(EBUSY);
		goto fail;
	}
	if (ro != 0) {
		err = SET_ERROR(EROFS);
		goto fail;
	}
	if (dmu_object_info(os, object, &doi) != 0 ||
	    doi.doi_type != (type == DMU_OST_ZVOL ?
	    DMU_OT_ZVOL : DMU_OT_PLAIN_FILE_CONTENTS)) {
		err = SET_ERROR(ENOENT);
		goto fail;
	}
	err = dnode_hold(os, object, &zfs_clonedup_tag, &dn);
	if (err != 0)
		goto fail;

	dst = kmem_zalloc(sizeof (*dst), KM_SLEEP);
	dst->zcd_object = object;
	dst->zcd_os = os;
	dst->zcd_dn = dn;
	*dstp = dst;
	return (0);

fail:
	dmu_objset_disown(os, B_FALSE, &zfs_clonedup_tag);
	return (err);
}

/*
 * A destination in an objset the caller already owns, such as the
 * dataset a receive is writing into.  The handle borrows that
 * ownership and gives back only the dnode.
 */
int
zfs_clonedup_dst_wrap(objset_t *os, uint64_t object,
    zfs_clonedup_dst_t **dstp)
{
	dmu_object_info_t doi;
	zfs_clonedup_dst_t *dst;
	dnode_t *dn;
	int err;

	if (dmu_object_info(os, object, &doi) != 0 ||
	    (doi.doi_type != DMU_OT_PLAIN_FILE_CONTENTS &&
	    doi.doi_type != DMU_OT_ZVOL))
		return (SET_ERROR(ENOENT));
	err = dnode_hold(os, object, &zfs_clonedup_tag, &dn);
	if (err != 0)
		return (err);
	dst = kmem_zalloc(sizeof (*dst), KM_SLEEP);
	dst->zcd_object = object;
	dst->zcd_os = os;
	dst->zcd_dn = dn;
	dst->zcd_borrowed = B_TRUE;
	*dstp = dst;
	return (0);
}

/*
 * The mounted or open path is tried first, ownership second, and the
 * first path once more if the dataset was mounted or opened between
 * the two.  Whatever is left is EBUSY and counted as such.
 */
int
zfs_clonedup_dst_open(spa_t *spa, uint64_t dsobj, uint64_t object,
    zfs_clonedup_dst_t **dstp)
{
	dsl_pool_t *dp = spa_get_dsl(spa);
	dmu_objset_type_t type = DMU_OST_NONE;
	char *name;
	int err;

	*dstp = NULL;
	name = kmem_alloc(ZFS_MAX_DATASET_NAME_LEN, KM_SLEEP);
	err = zfs_clonedup_dst_lookup(dp, dsobj, &type, name);
	if (err != 0)
		goto out;

	if (type == DMU_OST_ZVOL) {
		err = zfs_clonedup_zvol_open(name, object, dstp);
		if (err == EBUSY)
			err = zfs_clonedup_own_open(spa, dsobj,
			    object, type, dstp);
		if (err == EBUSY)
			err = zfs_clonedup_zvol_open(name, object,
			    dstp);
	} else if (type == DMU_OST_ZFS) {
		err = zfs_clonedup_file_open(spa, dsobj, object,
		    dstp);
		if (err == EBUSY)
			err = zfs_clonedup_own_open(spa, dsobj,
			    object, type, dstp);
		if (err == EBUSY)
			err = zfs_clonedup_file_open(spa, dsobj,
			    object, dstp);
	} else {
		err = SET_ERROR(ENOENT);
	}
out:
	kmem_free(name, ZFS_MAX_DATASET_NAME_LEN);
	return (err);
}

void
zfs_clonedup_dst_close(zfs_clonedup_dst_t *dst)
{
	if (dst->zcd_zv != NULL) {
		zfs_clonedup_zvol_close(dst->zcd_zv);
	} else if (dst->zcd_os != NULL) {
		dnode_rele(dst->zcd_dn, &zfs_clonedup_tag);
		if (!dst->zcd_borrowed) {
			dmu_objset_disown(dst->zcd_os, B_FALSE,
			    &zfs_clonedup_tag);
		}
	} else {
		zfsvfs_t *zfsvfs = dst->zcd_zfsvfs;

		zrele(dst->zcd_zp);
		zfs_exit(zfsvfs, &zfs_clonedup_tag);
		zfs_vfs_rele(zfsvfs);
	}
	kmem_free(dst, sizeof (*dst));
}

objset_t *
zfs_clonedup_dst_objset(zfs_clonedup_dst_t *dst)
{
	if (dst->zcd_zv != NULL)
		return (dst->zcd_zv->zv_objset);
	if (dst->zcd_os != NULL)
		return (dst->zcd_os);
	return (dst->zcd_zfsvfs->z_os);
}

uint64_t
zfs_clonedup_dst_object(zfs_clonedup_dst_t *dst)
{
	return (dst->zcd_object);
}

static dmu_object_type_t
zfs_clonedup_dst_type(zfs_clonedup_dst_t *dst)
{
	if (dst->zcd_zv != NULL)
		return (DMU_OT_ZVOL);
	if (dst->zcd_os != NULL)
		return (dst->zcd_dn->dn_type);
	return (DMU_OT_PLAIN_FILE_CONTENTS);
}

dsl_clonedup_kstat_id_t
zfs_clonedup_dst_kind(zfs_clonedup_dst_t *dst)
{
	if (dst->zcd_zv != NULL)
		return (DCK_DST_ZVOL);
	if (dst->zcd_os != NULL)
		return (DCK_DST_OWNED);
	return (DCK_DST_MOUNTED);
}

/*
 * True when this handle took the dataset with dmu_objset_own(),
 * which no second worker can hold.  A mounted filesystem is pinned
 * by a reference and an open volume by a reader, and several
 * workers can hold either at once.
 */
boolean_t
zfs_clonedup_dst_exclusive(zfs_clonedup_dst_t *dst)
{
	return (dst->zcd_os != NULL && !dst->zcd_borrowed);
}

/* the same cross-dataset rule as zfs_clone_range_precheck() */
static boolean_t
zfs_clonedup_cross_ok(objset_t *sos, objset_t *os)
{
	if (!zfs_bclone_strict_properties || sos == os ||
	    dmu_objset_is_snapshot(sos))
		return (B_TRUE);
	return (sos->os_checksum == os->os_checksum &&
	    sos->os_compress == os->os_compress &&
	    sos->os_copies == os->os_copies &&
	    sos->os_dedup_checksum == os->os_dedup_checksum);
}

static zfs_locked_range_t *
zfs_clonedup_lock(zfs_rangelock_t *rl, uint64_t off, uint64_t len,
    boolean_t nowait)
{
	if (nowait)
		return (zfs_rangelock_tryenter(rl, off, len,
		    RL_WRITER));
	return (zfs_rangelock_enter(rl, off, len, RL_WRITER));
}

/*
 * The three prep functions run the policy checks of their kind and
 * confirm the block still exists at that size.  They return a policy
 * errno, or 0 with *gop set when the block may be cloned and, for
 * files and volumes, *lrp holding its range lock.  With *gop clear,
 * *resp says why not.  With nowait set, a file or a volume returns
 * EAGAIN, holding nothing, where it would otherwise wait for the
 * range lock, and a file skips writing out its cached pages, since
 * writeback takes range locks too.  That is safe: writeback later
 * stores a page dirtied through a mapping over the clone.
 */
static int
zfs_clonedup_file_prep(zfs_clonedup_dst_t *dst, uint64_t off,
    uint64_t blksz, objset_t *sos, boolean_t nowait,
    zfs_locked_range_t **lrp, boolean_t *gop,
    zfs_clonedup_result_t *resp)
{
	znode_t *zp = dst->zcd_zp;
	zfsvfs_t *zfsvfs = dst->zcd_zfsvfs;
	uint64_t uid, gid, projid;

	if (zfs_verify_zp(zp) != 0 || !S_ISREG(zp->z_mode)) {
		*resp = ZCR_DST_STALE;
		return (0);
	}
	if (zfs_is_readonly(zfsvfs))
		return (SET_ERROR(EROFS));
	if (zp->z_pflags & ZFS_IMMUTABLE)
		return (SET_ERROR(EPERM));
	if (!zfs_clonedup_cross_ok(sos, zfsvfs->z_os))
		return (SET_ERROR(EXDEV));

	uid = KUID_TO_SUID(ZTOUID(zp));
	gid = KGID_TO_SGID(ZTOGID(zp));
	projid = zp->z_projid;
	if (zfs_id_overblockquota(zfsvfs, DMU_USERUSED_OBJECT, uid) ||
	    zfs_id_overblockquota(zfsvfs,
	    DMU_GROUPUSED_OBJECT, gid) ||
	    (projid != ZFS_DEFAULT_PROJID &&
	    zfs_id_overblockquota(zfsvfs,
	    DMU_PROJECTUSED_OBJECT, projid)))
		return (SET_ERROR(EDQUOT));

	if (!nowait && zn_has_cached_data(zp, off, off + blksz - 1))
		zn_flush_cached_data(zp, B_TRUE);

	*lrp = zfs_clonedup_lock(&zp->z_rangelock, off, blksz,
	    nowait);
	if (*lrp == NULL)
		return (SET_ERROR(EAGAIN));
	if (zp->z_blksz != blksz || off >= zp->z_size) {
		zfs_rangelock_exit(*lrp);
		*lrp = NULL;
		*resp = ZCR_DST_STALE;
		return (0);
	}
	*gop = B_TRUE;
	return (0);
}

static int
zfs_clonedup_zvol_prep(zfs_clonedup_dst_t *dst, uint64_t off,
    uint64_t blksz, objset_t *sos, boolean_t nowait,
    zfs_locked_range_t **lrp, boolean_t *gop,
    zfs_clonedup_result_t *resp)
{
	zvol_state_t *zv = dst->zcd_zv;

	if (zv->zv_flags & ZVOL_RDONLY)
		return (SET_ERROR(EROFS));
	if (!zfs_clonedup_cross_ok(sos, zv->zv_objset))
		return (SET_ERROR(EXDEV));

	*lrp = zfs_clonedup_lock(&zv->zv_rangelock, off, blksz,
	    nowait);
	if (*lrp == NULL)
		return (SET_ERROR(EAGAIN));
	if (zv->zv_volblocksize != blksz || off >= zv->zv_volsize) {
		zfs_rangelock_exit(*lrp);
		*lrp = NULL;
		*resp = ZCR_DST_STALE;
		return (0);
	}
	*gop = B_TRUE;
	return (0);
}

static int
zfs_clonedup_own_prep(zfs_clonedup_dst_t *dst, uint64_t off,
    uint64_t blksz, objset_t *sos, boolean_t *gop,
    zfs_clonedup_result_t *resp)
{
	dmu_object_info_t doi;

	if (!zfs_clonedup_cross_ok(sos, dst->zcd_os))
		return (SET_ERROR(EXDEV));

	dmu_object_info_from_dnode(dst->zcd_dn, &doi);
	if (doi.doi_data_block_size != blksz ||
	    off >= doi.doi_max_offset) {
		*resp = ZCR_DST_STALE;
		return (0);
	}
	*gop = B_TRUE;
	return (0);
}

static void
zfs_clonedup_tx_hold_clone(dmu_tx_t *tx, zfs_clonedup_dst_t *dst,
    uint64_t off, uint64_t blksz)
{
	dmu_buf_impl_t *db;

	if (dst->zcd_zv != NULL) {
		dmu_tx_hold_clone_by_dnode(tx, dst->zcd_zv->zv_dn,
		    off, blksz, blksz);
		return;
	}
	if (dst->zcd_os != NULL) {
		dmu_tx_hold_clone_by_dnode(tx, dst->zcd_dn, off,
		    blksz, blksz);
		return;
	}
	db = (dmu_buf_impl_t *)sa_get_db(dst->zcd_zp->z_sa_hdl);
	DB_DNODE_ENTER(db);
	dmu_tx_hold_clone_by_dnode(tx, DB_DNODE(db), off, blksz,
	    blksz);
	DB_DNODE_EXIT(db);
}

static void
zfs_clonedup_unlock(zfs_locked_range_t *lr)
{
	if (lr != NULL)
		zfs_rangelock_exit(lr);
}

/*
 * See dsl_clonedup_src_in_range().  A volume shrunk by zfs set
 * volsize takes zv_suspend_lock, not the range lock the apply holds,
 * so a destination can move out from under a checked offset too.
 */
static int
zfs_clonedup_src_in_range(objset_t *os, uint64_t object, uint64_t off,
    uint64_t blksz)
{
	dmu_object_info_t doi;
	int err;

	err = dmu_object_info(os, object, &doi);
	if (err != 0)
		return (err);
	if (doi.doi_data_block_size != blksz ||
	    off + blksz > doi.doi_max_offset)
		return (SET_ERROR(ESTALE));
	return (0);
}

int
zfs_clonedup_dst_prepare(zfs_clonedup_dst_t *dst, uint64_t blkid,
    const blkptr_t *dexp, objset_t *sos, boolean_t nowait,
    boolean_t *readyp, void **lockp, zfs_clonedup_result_t *resp)
{
	objset_t *os = zfs_clonedup_dst_objset(dst);
	uint64_t object = dst->zcd_object;
	uint64_t blksz = BP_GET_LSIZE(dexp);
	uint64_t off = blkid * blksz;
	zfs_locked_range_t *lr = NULL;
	boolean_t go = B_FALSE;
	blkptr_t bp;
	size_t nb = 1;
	int err;

	*readyp = B_FALSE;
	*lockp = NULL;
	*resp = ZCR_ERROR;

	if (dst->zcd_zv != NULL)
		err = zfs_clonedup_zvol_prep(dst, off, blksz, sos,
		    nowait, &lr, &go, resp);
	else if (dst->zcd_os != NULL)
		err = zfs_clonedup_own_prep(dst, off, blksz, sos, &go,
		    resp);
	else
		err = zfs_clonedup_file_prep(dst, off, blksz, sos,
		    nowait, &lr, &go, resp);
	if (err != 0 || !go) {
		zfs_clonedup_unlock(lr);
		return (err);
	}

	err = zfs_clonedup_src_in_range(os, object, off, blksz);
	if (err != 0) {
		*resp = ZCR_DST_STALE;
		zfs_clonedup_unlock(lr);
		return (0);
	}
	err = dmu_read_l0_bps(os, object, off, blksz, &bp, &nb);
	if (err == EAGAIN) {
		*resp = ZCR_DST_DIRTY;
		zfs_clonedup_unlock(lr);
		return (0);
	}
	if (err != 0 || nb != 1 ||
	    !dsl_clonedup_bp_same_block(&bp, dexp)) {
		*resp = ZCR_DST_STALE;
		zfs_clonedup_unlock(lr);
		return (0);
	}
	*readyp = B_TRUE;
	*lockp = lr;
	*resp = ZCR_QUEUED;
	return (0);
}

void
zfs_clonedup_dst_tx_hold(dmu_tx_t *tx, zfs_clonedup_dst_t *dst,
    uint64_t blkid, uint64_t blksz, boolean_t punch)
{
	uint64_t off = blkid * blksz;

	if (punch)
		dmu_tx_hold_free(tx, dst->zcd_object, off, blksz);
	else
		zfs_clonedup_tx_hold_clone(tx, dst, off, blksz);
}

void
zfs_clonedup_dst_unlock(void *lock)
{
	zfs_clonedup_unlock((zfs_locked_range_t *)lock);
}

/*
 * Read and check one source block pointer inside the transaction.
 * A batch calls this once for a run of destinations that share a
 * source: the apply visits them together and they are all in this
 * transaction, so nothing can change between them.
 */
int
zfs_clonedup_src_validate(objset_t *sos, uint64_t sobj,
    uint64_t sblkid, const blkptr_t *sexp, blkptr_t *bp,
    zfs_clonedup_result_t *resp)
{
	uint64_t sblksz = BP_GET_LSIZE(sexp);
	uint64_t soff = sblkid * sblksz;
	size_t nb = 1;
	int err;

	err = zfs_clonedup_src_in_range(sos, sobj, soff, sblksz);
	if (err == 0)
		err = dmu_read_l0_bps(sos, sobj, soff, sblksz, bp,
		    &nb);
	if (err == EAGAIN) {
		*resp = ZCR_SRC_DIRTY;
		return (0);
	}
	if (err != 0 || nb != 1 ||
	    !dsl_clonedup_bp_same_block(bp, sexp)) {
		*resp = ZCR_SRC_STALE;
		return (0);
	}
	*resp = ZCR_APPLIED;
	return (0);
}

/*
 * Finish one prepared block inside a transaction the caller assigned
 * and, unless the source is a snapshot, already waited out the
 * previous txg for.  The destination range lock has been held since
 * zfs_clonedup_dst_prepare(), so only the source and a volume that
 * shrank behind the range lock still need re-checking.
 */
int
zfs_clonedup_dst_finish(zfs_clonedup_dst_t *dst, uint64_t blkid,
    uint64_t blksz, objset_t *sos, uint64_t sobj, uint64_t sblkid,
    const blkptr_t *sexp, const blkptr_t *sval, boolean_t punch,
    dmu_tx_t *tx, zfs_clonedup_result_t *resp)
{
	objset_t *os = zfs_clonedup_dst_objset(dst);
	uint64_t object = dst->zcd_object;
	uint64_t off = blkid * blksz;
	blkptr_t bp;
	int err;

	*resp = ZCR_ERROR;

	if (punch) {
		err = dmu_free_range(os, object, off, blksz, tx);
		*resp = (err == 0) ? ZCR_APPLIED : ZCR_ERROR;
		return (err);
	}

	if (sval != NULL) {
		bp = *sval;
	} else {
		err = zfs_clonedup_src_validate(sos, sobj, sblkid,
		    sexp, &bp, resp);
		if (err != 0 || *resp != ZCR_APPLIED)
			return (err);
	}
	err = zfs_clonedup_src_in_range(os, object, off, blksz);
	if (err != 0) {
		*resp = ZCR_DST_STALE;
		return (0);
	}
	/*
	 * A pointer's type names the object holding it, so the copy a
	 * volume takes of a file's block, or a file of a volume's,
	 * carries the destination's.  The data and checksum are one.
	 */
	BP_SET_TYPE(&bp, zfs_clonedup_dst_type(dst));
	err = dmu_brt_clone(os, object, off, blksz, tx, &bp, 1);
	*resp = (err == 0) ? ZCR_APPLIED : ZCR_ERROR;
	return (err);
}

/*
 * Replace block blkid of the destination, expected to still be dexp,
 * with a clone of the source block, expected to still be sexp.  With
 * punch set the block is known to be all zeros and is freed instead.
 * Returns a policy errno (EPERM, EROFS, EDQUOT, EXDEV) or an I/O
 * errno; *resp says what happened otherwise.
 *
 * The destination is protected by its range lock or by ownership.
 * The source is not locked at all: a writer may already hold a
 * transaction in the txg before ours without having dirtied the block
 * yet, and a clone of the bp it is about to free would reference
 * freed space once both txgs sync.  Waiting for the previous txg
 * after assigning ours makes every such writer visible, either as a
 * dirty record or as a changed bp.  Writers in our own txg dirty
 * after our clone, and brt_pending_apply() runs before any free of a
 * txg, so those are safe.  A writer in a later txg either dirtied the
 * block before we read its bp, which dmu_read_l0_bps() reports as
 * EAGAIN, or frees it in a txg that syncs after ours.
 */
int
zfs_clonedup_dst_apply(zfs_clonedup_dst_t *dst, uint64_t blkid,
    const blkptr_t *dexp, objset_t *sos, uint64_t sobj,
    uint64_t sblkid, const blkptr_t *sexp, boolean_t punch,
    zfs_clonedup_result_t *resp)
{
	objset_t *os = zfs_clonedup_dst_objset(dst);
	dsl_pool_t *dp = dmu_objset_pool(os);
	uint64_t blksz = BP_GET_LSIZE(dexp);
	boolean_t ready = B_FALSE;
	void *lock = NULL;
	dmu_tx_t *tx;
	int err;

	err = zfs_clonedup_dst_prepare(dst, blkid, dexp, sos, B_FALSE,
	    &ready, &lock, resp);
	if (err != 0 || !ready)
		return (err);

	do {
		tx = dmu_tx_create(os);
		zfs_clonedup_dst_tx_hold(tx, dst, blkid, blksz,
		    punch);
		err = dmu_tx_assign(tx, DMU_TX_WAIT);
		if (err != 0) {
			dmu_tx_abort(tx);
			zfs_clonedup_dst_unlock(lock);
			return (err);
		}
	} while (!dsl_clonedup_apply_paced(tx, 1));

	if (!punch) {
		err = txg_wait_synced_flags(dp,
		    dmu_tx_get_txg(tx) - 1, TXG_WAIT_SUSPEND);
		if (err != 0) {
			dmu_tx_commit(tx);
			zfs_clonedup_dst_unlock(lock);
			return (err);
		}
	}
	err = zfs_clonedup_dst_finish(dst, blkid, blksz, sos, sobj,
	    sblkid, sexp, NULL, punch, tx, resp);
	dmu_tx_commit(tx);
	zfs_clonedup_dst_unlock(lock);
	return (err);
}
