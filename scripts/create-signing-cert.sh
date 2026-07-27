#!/usr/bin/env bash
#
# Create the local code-signing certificate Fovea.app is signed with.
#
# WHY THIS EXISTS
#
# TCC stores a permission grant against the app's code-signing "designated
# requirement". For an AD-HOC signature that requirement is:
#
#     designated => cdhash H"ae4816a8025f5297ddf8b33080ad0454dfd8f55a"
#
# — the hash of that exact binary. Rebuild, and the grant no longer matches
# anything, so all four permissions silently die. The Accessibility entry stays
# visibly ticked while behaving as denied, which is worse than an obvious break.
#
# Signed with a stable certificate the requirement becomes:
#
#     designated => identifier "com.fovea.capture" and certificate leaf = H"c5d9…"
#
# — which does NOT change when the binary does. Verified by signing two
# different binaries and diffing the requirement.
#
# WHY A SCRIPT RATHER THAN "open Keychain Access"
#
# Keychain Access.app was removed in macOS 26. The certificate assistant it
# hosted went with it, so the documented GUI route no longer exists on a current
# Mac. This does the same thing with `openssl` and `security`.
#
# The certificate is NOT trusted, and does not need to be: `codesign` signs with
# an untrusted local certificate quite happily, and trusting it would mean an
# authorisation prompt and a root certificate in your trust store for no gain.
# The consequence is that `security find-identity -v` will not list it — hence
# the Makefile matching on `find-identity` without `-v`.
#
# To undo everything this does:
#     security delete-identity -c "Fovea Local" ~/Library/Keychains/login.keychain-db

set -euo pipefail

NAME="${1:-Fovea Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ '$NAME' already exists — nothing to do"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name   = dn
x509_extensions      = v3
prompt               = no
[dn]
CN = $NAME
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
# This is the extension that makes it a CODE SIGNING certificate rather than a
# generic one. Without it codesign refuses the identity.
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "  generating a 10-year self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -config "$work/cert.cnf" 2>/dev/null

# -legacy is required. OpenSSL 3 defaults to AES-256-CBC with a SHA-256 MAC,
# which macOS's `security import` cannot read — it fails with the thoroughly
# misleading "MAC verification failed during PKCS12 import (wrong password?)".
openssl pkcs12 -export -legacy \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/bundle.p12" -passout pass:fovea -name "$NAME" 2>/dev/null

# -A lets any app use the key without a per-use authorisation dialog. The
# alternative (-T /usr/bin/codesign) needs `set-key-partition-list`, which wants
# your login password — friction, for a key whose only power is signing a local
# debug build of this app.
echo "  importing into the login keychain…"
security import "$work/bundle.p12" -k "$KEYCHAIN" -P fovea -A >/dev/null

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ '$NAME' created"
else
    echo "✗ import reported success but the identity is not visible" >&2
    exit 1
fi
