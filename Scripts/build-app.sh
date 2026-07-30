#!/usr/bin/env bash
# Build Kalamos via Xcode's build system (REQUIRED — it compiles mlx-swift's Metal
# shaders into default.metallib, which `swift build` does NOT do) and wrap the
# product into a .app bundle, copying the SwiftPM resource bundles (incl.
# mlx-swift_Cmlx.bundle with default.metallib) next to the executable so MLX +
# WhisperKit find their resources at runtime.
#
# Usage: ./Scripts/build-app.sh [Debug|Release]
set -euo pipefail

CONFIG="${1:-Debug}"
case "$CONFIG" in debug) CONFIG=Debug;; release) CONFIG=Release;; esac

APP_NAME="Kalamos"
DERIVED=".build/xc"
PRODUCTS="${DERIVED}/Build/Products/${CONFIG}"
BUNDLE_DIR="build/${APP_NAME}.app"

echo "▶ xcodebuild (${CONFIG}) — compiles MLX Metal shaders…"
xcodebuild -scheme "${APP_NAME}" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED}" -configuration "${CONFIG}" build \
    > /tmp/kalamos_xcbuild.log 2>&1 \
    || { echo "✗ xcodebuild failed:"; tail -25 /tmp/kalamos_xcbuild.log; exit 1; }

[ -f "${PRODUCTS}/${APP_NAME}" ] || { echo "✗ executable not at ${PRODUCTS}/${APP_NAME}"; exit 1; }
[ -f "${PRODUCTS}/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ] \
    || echo "⚠ default.metallib not found — MLX features may fail"

echo "▶ assembling ${BUNDLE_DIR}…"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Resources"
cp "${PRODUCTS}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
# In an .app, SwiftPM resource bundles are resolved via Bundle.main.resourceURL,
# i.e. Contents/Resources/ — NOT next to the executable.
for b in "${PRODUCTS}"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "${BUNDLE_DIR}/Contents/Resources/"
done
cp "Sources/Kalamos/Resources/Kalamos-Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
[ -f "Sources/Kalamos/Resources/AppIcon.icns" ] && cp "Sources/Kalamos/Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

# Stable identity if available (persistent permissions), else ad-hoc.
IDENTITY="Kalamos Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "▶ codesign with stable identity \"${IDENTITY}\"…"
    codesign --force --deep --sign "${IDENTITY}" "${BUNDLE_DIR}"
else
    echo "▶ ad-hoc codesign (run Scripts/make-signing-cert.sh once for persistent permissions)…"
    codesign --force --deep --sign - "${BUNDLE_DIR}"
fi

echo "✓ Built ${BUNDLE_DIR}"

# CI builds the release artifact with this same script — one assembly path, so a
# release can never be put together differently from the build you tested locally
# — but must stop here: there is nothing to install into and nothing to relaunch.
if [ -n "${KALAMOS_NO_INSTALL:-}" ]; then
    echo "✓ KALAMOS_NO_INSTALL set — skipping install + relaunch"
    exit 0
fi

# Install to /Applications so it's launchable from Spotlight/Launchpad by name.
# Falls back to ~/Applications if /Applications isn't writable. Stable signing
# means TCC permissions follow the app regardless of which copy you launch.
INSTALL_DIR="/Applications"
if [ ! -w "${INSTALL_DIR}" ]; then INSTALL_DIR="${HOME}/Applications"; mkdir -p "${INSTALL_DIR}"; fi
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
if cp -R "${BUNDLE_DIR}" "${INSTALL_DIR}/" 2>/dev/null; then
    echo "✓ Installed to ${INSTALL_DIR}/${APP_NAME}.app — open from Spotlight (⌘Space → \"Kalamos\")"
    LAUNCH="${INSTALL_DIR}/${APP_NAME}.app"
else
    echo "⚠ Could not install to ${INSTALL_DIR}; run from ${BUNDLE_DIR}"
    LAUNCH="${BUNDLE_DIR}"
fi

# Always relaunch the FRESH binary. `open` on an already-running menu-bar app
# only foregrounds the old in-memory instance, so kill it first — otherwise you
# test a stale build and chase ghosts.
killall "${APP_NAME}" 2>/dev/null && sleep 1 || true
open "${LAUNCH}"
echo "✓ Relaunched ${LAUNCH}"
