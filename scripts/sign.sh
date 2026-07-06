#!/bin/sh
# sign.sh — detached-sign build artifacts with the repo signing key.
#
#   scripts/sign.sh FILE [FILE...]     ->  FILE.sig next to each
#
# GRUB's pgp verifier wants a binary detached signature named <file>.sig.
# Existing .sig files are replaced (artifacts get rebuilt; stale signatures
# are worse than none, because enforcement makes them boot failures).
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
export GNUPGHOME="$HERE/keys/gnupg"

[ -f "$HERE/keys/zurvan-signing.pub" ] \
	|| { echo "!! no signing key — run scripts/make-keys.sh first" >&2; exit 1; }

for f in "$@"; do
	[ -f "$f" ] || { echo "!! no such file: $f" >&2; exit 1; }
	rm -f "$f.sig"
	gpg --batch --quiet --detach-sign -o "$f.sig" "$f"
done
