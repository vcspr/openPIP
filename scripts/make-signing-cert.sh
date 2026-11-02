#!/bin/bash
# Make a self-signed code signing certificate in the login keychain, for scripts/build-app.sh.
#
#   scripts/make-signing-cert.sh            -> "OpenPiP Self-Signed"
#
# Why: an ad-hoc signed app is known to macOS only by a hash of its files, so every build looks
# like a new app and loses its Screen Recording permission. Signed with one certificate, every
# build has the same identity and keeps the permission. This is not an Apple Developer ID: macOS
# still asks "Open Anyway" once on first install. Nothing is trusted system-wide.
#
# Keep the certificate: a new one changes the identity again (one more permission prompt).
set -euo pipefail

NAME="${1:-OpenPiP Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" is already in the login keychain."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` reads without extra flags.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(uuidgen)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS"
# -T lets codesign use the key without asking each time.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to the login keychain."
