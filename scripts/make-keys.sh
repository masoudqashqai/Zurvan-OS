#!/bin/sh
# make-keys.sh — generate the image-signing keypair (v2 M3, "the seal").
#
# One RSA-4096 GPG key, living in a repo-local keyring (keys/, gitignored).
# The PRIVATE key never leaves the build machine and never has a passphrase
# (it signs unattended builds; protect the build machine instead). The PUBLIC
# key gets baked into GRUB's core image, which turns on signature enforcement
# for everything GRUB loads — kernel, initrd, config, modules.
#
# Key hygiene, stated plainly:
#   - keys/ is gitignored; committing it would let anyone sign images.
#   - Losing keys/ is not a disaster: generate a new pair and reinstall the
#     boxes (the key of trust is delivered with the install media).
#   - Rotating = same as losing, on purpose.
#
# Output:
#   keys/gnupg/            the keyring (GNUPGHOME)
#   keys/zurvan-signing.pub    binary public key, for grub-mkimage --pubkey
#                              and for gpgv on the box (upgrade verification)
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="$HERE/keys"
export GNUPGHOME="$KEYDIR/gnupg"

if [ -f "$KEYDIR/zurvan-signing.pub" ]; then
	echo ">> keys already exist at $KEYDIR — not overwriting."
	echo ">> (delete the directory yourself if you really mean to re-key)"
	exit 0
fi

mkdir -p "$GNUPGHOME"
chmod 700 "$KEYDIR" "$GNUPGHOME"

echo ">> generating the Zurvan image-signing key (RSA-4096, no passphrase)"
gpg --batch --quiet --gen-key <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Zurvan image signing
Name-Email: signing@zurvan.local
Expire-Date: 0
%commit
EOF

gpg --batch --quiet --export "signing@zurvan.local" > "$KEYDIR/zurvan-signing.pub"

echo ">> done:"
gpg --batch --list-keys --keyid-format long "signing@zurvan.local" | sed 's/^/   /'
echo "   public key: $KEYDIR/zurvan-signing.pub"
