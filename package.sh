#!/bin/sh
# Build the t2-bootloader Debian package from the artefacts in build/out/.
#
# A hand-written DEBIAN/ control directory plus `dpkg-deb --build` (no
# debhelper, no debian/rules): the payload is a flat file tree with one
# maintainer script, so dh_installdirs/dh_install*/dh_md5sums would only add a
# build dependency and a source package nobody builds.  `--root-owner-group`
# normalises the uid/gid (the build runs unprivileged) and SOURCE_DATE_EPOCH
# pins every ar/tar member mtime, so the same tree builds the same .deb bytes.
#
# The version is this repository's `git describe`, so the package is the U-Boot
# release it was built from plus a Debian revision:
#
#   tag v2026.07              -> 2026.07-1
#   v2026.07-3-g1a2b3c4       -> 2026.07+git3.g1a2b3c4-1   (post-release commits)
#   v2026.07-rc5-3-g1a2b3c4   -> 2026.07~rc5+git3.g1a2b3c4-1
#
# The `~` matters: Debian sorts `2026.07~rc5` *before* `2026.07`, which is what
# a pre-release tag means; `+git` sorts after the plain release.  A tag less
# checkout (CI without tags) falls back to the U-Boot release fetch.sh pins.
#
# Usage: ./package.sh [OUTDIR]
#   OUTDIR  where the .deb and a SHA256SUMS land; default <repo>/build
#
# Environment: OUT (artefact directory, default <repo>/build/out),
#              DEB_REV (Debian revision, default 1).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$HERE
OUT=${OUT:-$ROOT/build/out}
DEST=${1:-$ROOT/build}
REV=${DEB_REV:-1}

FILES="u-boot.itb idbloader.img u-boot-installer.itb idbloader-installer.img \
u-boot-initial-env u-boot-installer-initial-env"

die() { echo "package.sh: $*" >&2; exit 1; }

# git describe -> Debian upstream version (see the header).  The dirty suffix
# is re-appended last: Debian forbids `-` inside an upstream version, so
# `v2026.07-3-gabc1234-dirty` must become `2026.07+git3.gabc1234+dirty`, not
# `2026.07-3-gabc1234+dirty`.
version_upstream() {
	desc=$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --dirty 2>/dev/null || true)
	if [ -z "$desc" ]; then
		# No tag in this checkout: the U-Boot release fetch.sh pins is the
		# only version-shaped fact here.
		desc=$(awk -F'=' '/^UBOOT_TAG=/{print $2}' "$ROOT/fetch.sh" |
			sed 's/^\${UBOOT_TAG:-//; s/}$//')
		[ -n "$desc" ] || die "no v* tag and no UBOOT_TAG in fetch.sh"
	fi
	up=$(printf '%s' "$desc" | sed \
		-e 's/^v//' \
		-e 's/-dirty$//' \
		-e 's/-\([0-9][0-9]*\)-g\([0-9a-f][0-9a-f]*\)$/+git\1.g\2/' \
		-e 's/-rc\([0-9][0-9]*\)/~rc\1/')
	case "$desc" in
	*-dirty) up=$up+dirty ;;
	esac
	printf '%s' "$up"
}

version=$(version_upstream)-$REV

for f in $FILES; do
	[ -f "$OUT/$f" ] || die "missing $OUT/$f - build first (./fetch.sh && ./build.sh)"
done
[ -x "$ROOT/t2-bootloader-install" ] || die "$ROOT/t2-bootloader-install is missing or not executable"

work=$ROOT/build/pkg
rm -rf "$work"
mkdir -p "$work/DEBIAN" "$work/usr/lib/t2-bootloader" "$work/usr/sbin"

for f in $FILES; do
	cp "$OUT/$f" "$work/usr/lib/t2-bootloader/$f"
done
chmod 644 "$work"/usr/lib/t2-bootloader/*
install -m 755 "$ROOT/t2-bootloader-install" "$work/usr/sbin/t2-bootloader-install"
# Directory modes come from the umask; pin them so the package does not inherit
# a group-writable build shell.
chmod 755 "$work" "$work/DEBIAN" "$work/usr" "$work/usr/lib" \
	"$work/usr/lib/t2-bootloader" "$work/usr/sbin"

# Installed-Size is an estimate in KiB.  --apparent-size, not the default block
# count: on the ZFS build pool `du -sk` reports freshly written files as 0 until
# the next transaction group commits, which produced an absurd Installed-Size.
installed_size=$(du -sk --apparent-size "$work/usr" | cut -f1)
sed -e "s/@VERSION@/$version/g" \
	-e "s/@INSTALLED_SIZE@/$installed_size/g" \
	"$ROOT/packaging/DEBIAN/control.in" > "$work/DEBIAN/control"

# Reproducible: dpkg-deb clamps every member mtime to SOURCE_DATE_EPOCH.
: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH

mkdir -p "$DEST"
deb=$DEST/t2-bootloader_${version}_arm64.deb
dpkg-deb --root-owner-group --build "$work" "$deb" >/dev/null

(cd "$DEST" && sha256sum "t2-bootloader_${version}_arm64.deb" > SHA256SUMS)
cat "$DEST/SHA256SUMS"
echo "$deb"
