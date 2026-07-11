#!/bin/sh
# make-catalog-pack.sh — pack the whole catalog as one downloadable release asset.
#
#   scripts/make-catalog-pack.sh
#     -> build/zurvan-catalog-<DATE>.tar.gz        the pack
#     -> build/zurvan-catalog-<DATE>.tar.gz.sig    detached signature
#     -> build/zurvan-catalog-<DATE>.tar.gz.sha256
#
# The pack is DATE-stamped (2026.07.11), not OS-versioned: the catalog has its
# own release cadence. An OS version means "the image changed"; a catalog
# release means "the curated set grew" — the whole point of the on-ISO split
# is that the second never implies the first. Packages are static binaries
# with no OS coupling, so any pack runs on any v2.x image. Publish it as its
# own GitHub release (tag catalog-<DATE>); OS releases carry only the ISO.
#
# The ISO carries only the tier in catalog/on-iso.txt, so that catalog growth
# never grows the ISO. This is where the rest of the catalog goes: you download
# it, verify it on your own machine, and feed packages to a box through the
# panel's upload button or scp.
#
# The pack holds EVERY package, including the ones already on the ISO. One
# artifact, no "which half do I have?" — the duplication costs a few megabytes
# on a release page and saves an explanation.
#
# Deliberately NOT a repository: nothing on the box fetches this over the
# network. See ROADMAP ("no `zurvan-pkg install <url>`") — the install path
# stays offline, and that is a security property, not an omission.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$HERE/build}"
CAT="$BUILD/catalog"
SIGN="$HERE/scripts/sign.sh"

VERSION="${CATALOG_VERSION:-$(date +%Y.%m.%d)}"
PACK="$BUILD/zurvan-catalog-$VERSION.tar.gz"

ls "$CAT"/*.tar.gz >/dev/null 2>&1 \
	|| { echo "!! no packages in $CAT — run 'make catalog' first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/zurvan-catalog-$VERSION"
mkdir -p "$ROOT"

# Every package carries a detached .sig — zurvan-pkg verifies it before
# unpacking, so the .sig must travel with the tarball all the way to /data.
# Re-sign here so the sigs always match the tarballs we actually pack.
if [ -f "$HERE/keys/zurvan-signing.pub" ]; then
	"$SIGN" "$CAT"/*.tar.gz
	cp "$CAT"/*.tar.gz "$CAT"/*.tar.gz.sig "$ROOT/"
else
	echo "!! no signing key — packages UNSIGNED, installs will refuse them" >&2
	cp "$CAT"/*.tar.gz "$ROOT/"
fi

# An INDEX the pack can be read with, without a running Zurvan. Mark which
# packages the ISO already carries so nobody wonders why they have them twice.
oniso_names=$(sed 's/#.*//' "$HERE/catalog/on-iso.txt" 2>/dev/null || true)
{
	echo "Zurvan package catalog $VERSION"
	echo
	echo "Install on a running box with a /data disk:"
	echo "    zurvan-pkg install <package>.tar.gz"
	echo "or upload it in the web panel's Packages page."
	echo
	echo "Each package has a detached .sig beside it. Keep them together:"
	echo "the box verifies the signature before unpacking and refuses without it."
	echo
	printf '%-28s %10s  %s\n' PACKAGE SIZE NOTE
	for p in "$ROOT"/*.tar.gz; do
		base=$(basename "$p")
		name=${base%%-*}
		note="pack only"
		for o in $oniso_names; do
			[ "$o" = "$name" ] && note="also on the ISO"
		done
		printf '%-28s %10s  %s\n' "$base" "$(wc -c <"$p")" "$note"
	done
} >"$ROOT/INDEX.txt"

tar -czf "$PACK" -C "$STAGE" "zurvan-catalog-$VERSION"
echo ">> catalog pack: $PACK ($(du -h "$PACK" | cut -f1), $(ls "$CAT"/*.tar.gz | wc -l) packages)"

# Same signing key as the images, so the pack verifies in either place:
# on your machine with gpg --verify, or on the box itself with the gpgv +
# trust anchor (/etc/zurvan-signing.pub) that every image already carries.
if [ -f "$HERE/keys/zurvan-signing.pub" ]; then
	"$SIGN" "$PACK"
	echo ">> signed: $PACK.sig"
else
	echo "!! no signing key — pack is UNSIGNED (run scripts/make-keys.sh)" >&2
fi

sha256sum "$PACK" | sed "s| .*/| |" >"$PACK.sha256"
echo ">> sha256:  $PACK.sha256"
