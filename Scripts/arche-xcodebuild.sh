#!/usr/bin/env bash
# La compilazione di Kalamos, che NON passa da `swift build`.
#
# Solo il build system di Xcode compila gli shader Metal di mlx-swift in `default.metallib`. Un
# bundle senza quel file sembra perfettamente sano finché qualcuno non accende la pulizia AI, e
# allora fallisce a runtime: per questo il controllo sul metallib sta qui, subito dopo, e non
# aspetta la CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Debug}"
DERIVED="$ROOT/.build/xc"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
LOG=/tmp/kalamos_xcbuild.log

cd "$ROOT"
xcodebuild -scheme Kalamos -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" -configuration "$CONFIG" build \
    > "$LOG" 2>&1 \
    || { echo "✘ xcodebuild è fallito:"; tail -25 "$LOG"; exit 1; }

[ -f "$PRODUCTS/Kalamos" ] || { echo "✘ l'eseguibile non è in $PRODUCTS/Kalamos"; exit 1; }

if [ -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    echo "  default.metallib c'è"
else
    echo "⚠ default.metallib non trovato: la pulizia AI fallirebbe a runtime" >&2
fi
