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

# whisper.cpp arriva come framework DINAMICO (2026-08-05), quindi va spedito
# dentro il bundle: il binario lo cerca a `@rpath/whisper.framework/...`, e in
# `.build` lo trova solo perché SwiftPM glielo mette accanto. Senza questo passo
# l'app compila, si firma, e poi non parte sul Mac di chi la scarica.
#
# Assottigliato ad arm64: la fetta universale pesa 35 MB e Kalamos gira solo su
# Apple Silicon, quindi metà di quei byte sarebbe x86_64 che nessuno esegue.
WHISPER_FW=""
for cand in "${PRODUCTS}/whisper.framework" \
            ".build/artifacts/kalamos/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework"; do
    [ -d "$cand" ] && { WHISPER_FW="$cand"; break; }
done
[ -n "${WHISPER_FW}" ] || { echo "✗ whisper.framework non trovato — il motore whisper.cpp non partirebbe"; exit 1; }
mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"
cp -R "${WHISPER_FW}" "${BUNDLE_DIR}/Contents/Frameworks/"
FW_BIN="${BUNDLE_DIR}/Contents/Frameworks/whisper.framework/Versions/A/whisper"
if lipo -info "${FW_BIN}" 2>/dev/null | grep -q x86_64; then
    lipo -thin arm64 "${FW_BIN}" -output "${FW_BIN}.arm64" && mv "${FW_BIN}.arm64" "${FW_BIN}"
fi
# `@executable_path/../Frameworks` è il posto standard; si aggiunge solo se manca,
# perché install_name_tool duplica volentieri.
if ! otool -l "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
fi
echo "▶ whisper.framework incorporato ($(du -sh "${BUNDLE_DIR}/Contents/Frameworks/whisper.framework" | cut -f1))"

# The version the app reports must be the version being shipped.
#
# Info.plist otherwise carries whatever number was last typed into it by hand,
# and nobody remembers to type it: release v0.1.1 ships a binary that answers
# "Kalamos 0.1.0" to --version and shows 0.1.0 in Get Info. The release workflow
# passes the tag in here, and then refuses to publish if the two disagree.
if [ -n "${KALAMOS_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${KALAMOS_VERSION}" \
        "${BUNDLE_DIR}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${KALAMOS_VERSION}" \
        "${BUNDLE_DIR}/Contents/Info.plist"
    echo "▶ version ${KALAMOS_VERSION}"
fi

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
    # The staging copy goes, and this is not tidiness.
    #
    # It stayed here for months, Spotlight indexed it, and typing "Kalamos"
    # returned TWO results that look identical. Open both and there are two
    # global event taps on the same key: every dictation typed twice. That reads
    # as a broken app, not as two apps, which is why it cost an evening even to
    # name (2026-08-01).
    rm -rf "${BUNDLE_DIR}"
    echo "✓ Removed the staging copy — exactly one ${APP_NAME}.app exists"
else
    echo "⚠ Could not install to ${INSTALL_DIR}; run from ${BUNDLE_DIR}"
    LAUNCH="${BUNDLE_DIR}"
fi

# Always relaunch the FRESH binary. `open` on an already-running menu-bar app
# only foregrounds the old in-memory instance, so kill it first — otherwise you
# test a stale build and chase ghosts.
#
# By PATH and not by name (2026-08-05). `killall Kalamos` matches every process
# called Kalamos, and a headless probe — `--selftest-engine`, `--bench-clean`,
# any of them — is called Kalamos too. It killed a 1,6 GB model download at 534
# MB, half an hour in, from a terminal that had nothing to do with the build. The
# GUI instance is the one running from the installed bundle; nothing else is.
pkill -f "${LAUNCH}/Contents/MacOS/${APP_NAME}" 2>/dev/null && sleep 1 || true
open "${LAUNCH}"
echo "✓ Relaunched ${LAUNCH}"
