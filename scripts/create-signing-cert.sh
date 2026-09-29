#!/usr/bin/env bash
#
# Create the local code-signing certificate Deiko.app is signed with.
#
# TCC stores a permission grant against the app's designated requirement. For an
# ad-hoc signature that is the binary's cdhash, so every rebuild invalidates the
# grants (Accessibility stays ticked while behaving as denied). Signing with a
# stable certificate makes the requirement the bundle identifier plus the
# certificate, which survives rebuilds.
#
# This is a script because Keychain Access (and its certificate assistant) is
# gone on current macOS; it uses `openssl` and `security` instead.
#
# The certificate is deliberately not trusted: `codesign` signs with an
# untrusted local certificate, and trusting it would add a prompt and a root
# certificate for no gain. As a result `security find-identity -v` does not list
# it, so the Makefile matches on `find-identity` without `-v`.
#
# To remove it:
#     security delete-identity -c "Deiko Local" ~/Library/Keychains/login.keychain-db

set -euo pipefail

NAME="${1:-Deiko Local}"
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

# OpenSSL 3 defaults to a PKCS12 format that `security import` cannot read (it
# fails with a misleading "MAC verification failed ... wrong password?"), so it
# needs -legacy. macOS's stock LibreSSL has no -legacy flag but already emits
# the legacy format. Probe for the flag rather than assuming either.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- -legacy; then
    LEGACY="-legacy"
fi
openssl pkcs12 -export $LEGACY \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/bundle.p12" -passout pass:deiko -name "$NAME"

# -A lets any app use the key without a per-use authorisation dialog. The
# alternative (-T /usr/bin/codesign) needs `set-key-partition-list` and your
# login password, which is not worth it for a key that only signs local builds.
echo "  importing into the login keychain…"
security import "$work/bundle.p12" -k "$KEYCHAIN" -P deiko -A >/dev/null

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ '$NAME' created"
else
    echo "✗ import reported success but the identity is not visible" >&2
    exit 1
fi
