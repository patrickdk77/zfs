#!/usr/bin/env bash
#
# setup.sh -- prepare a machine to run the ZFS xfstests groups.
#
# Installs the fstests build deps, fetches + builds + installs the ZFS-aware
# fstests (implr/xfstests `zfs` branch), applies the topology patch, and
# creates the test users/dirs. Assumes the ZFS userland+module are already
# built/installed and loaded (in zfs-qemu that is qemu-3-deps + qemu-4-build).
#
# Run via sudo.
#
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
XFSTESTS_DIR=${XFSTESTS_DIR:-/var/tmp/xfstests}
XFSTESTS_REF=${XFSTESTS_REF:-zfs}                 # implr branch/tag
XFSTESTS_URL=${XFSTESTS_URL:-https://github.com/implr/xfstests/archive/refs/heads/$XFSTESTS_REF.tar.gz}

# --- deps ---------------------------------------------------------------
if command -v apt-get >/dev/null; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -yqq \
		build-essential autoconf automake libtool libtool-bin gawk pkg-config \
		xfslibs-dev libacl1-dev libaio-dev libattr1-dev libgdbm-dev \
		libgdbm-compat-dev e2fslibs-dev uuid-dev uuid-runtime libcap-dev \
		acl attr bc dbench fio quota xfsprogs liburing-dev ksh
elif command -v dnf >/dev/null; then
	dnf install -yq \
		autoconf automake libtool gawk pkgconf-pkg-config gcc make \
		xfsprogs-devel libacl-devel libaio-devel libattr-devel gdbm-devel \
		e2fsprogs-devel libuuid-devel libcap-devel \
		acl attr bc dbench fio quota xfsprogs liburing-devel ksh
else
	echo "unsupported distro (need apt-get or dnf)"; exit 1
fi

# --- fetch + build + install fstests ------------------------------------
tmp=$(mktemp -d)
curl -fsSL "$XFSTESTS_URL" -o "$tmp/xfstests.tar.gz"
rm -rf "$XFSTESTS_DIR"; mkdir -p "$XFSTESTS_DIR"
tar xzf "$tmp/xfstests.tar.gz" -C "$XFSTESTS_DIR" --strip-components=1
rm -rf "$tmp"

# topology patch: let ZFS_SCRATCH_VDEV drive the scratch pool layout
if ! grep -q ZFS_SCRATCH_VDEV "$XFSTESTS_DIR/common/zfs"; then
	( cd "$XFSTESTS_DIR" && patch -p1 < "$HERE/topology.patch" )
fi

( cd "$XFSTESTS_DIR" && make -j"$(nproc)" && make install )

# --- users + dirs -------------------------------------------------------
for u in fsgqa fsgqa2 123456-fsgqa; do id "$u" >/dev/null 2>&1 || useradd -m "$u"; done
getent group fsgqa >/dev/null || groupadd fsgqa
mkdir -p /mnt/test /mnt/scratch

echo "setup complete: fstests at $XFSTESTS_DIR (topology patch applied)"
