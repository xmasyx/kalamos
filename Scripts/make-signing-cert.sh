#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity ("Kalamos Dev") in the login
# keychain, so macOS treats every rebuild as the same app and the Accessibility /
# Microphone permission persists (ad-hoc signing changes identity every build).
#
# Run once:  ./Scripts/make-signing-cert.sh
set -euo pipefail

IDENTITY="Kalamos Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✓ Code-signing identity \"$IDENTITY\" already exists."
    exit 0
fi

# Remove any leftover (untrusted/failed) cert of the same name so re-runs are clean.
security delete-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = Kalamos Dev
[v3]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CNF

echo "▶ generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf"

# macOS `security import` rejects empty-password p12s ("MAC verification failed")
# and OpenSSL 3's default p12 MAC. Use a password + -legacy when available.
P12PASS="kalamos"
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/kalamos.p12" -passout "pass:$P12PASS" -name "$IDENTITY"

echo "▶ importing into login keychain (allowing codesign to use it)…"
security import "$TMP/kalamos.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign

# A self-signed cert isn't "valid" for codesign until trusted. This may pop a
# keychain dialog asking for your login password — approve it.
echo "▶ trusting the certificate for code signing (approve the keychain prompt)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || true

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✓ Created code-signing identity \"$IDENTITY\"."
    echo "  Rebuild with ./Scripts/build-app.sh — Accessibility will now persist across rebuilds."
else
    echo "✗ Identity not found after import. You may need to run this in a Terminal (Keychain may prompt)." >&2
    exit 1
fi
