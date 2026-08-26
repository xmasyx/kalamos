#!/usr/bin/env bash
# Costruisce Kalamos.app e la installa.
#
# È un involucro: il lavoro sta in Arche, in un solo script parametrico condiviso da tutte le app
# della famiglia. Le cose che valgono SOLO per Kalamos restano qui e in `arche-hooks.sh`, e sono
# quattro, ognuna con la sua ragione:
#
#   1. **si compila con `xcodebuild`, non con `swift build`.** Solo il build system di Xcode compila
#      gli shader Metal di mlx-swift in `default.metallib`. Con `swift build` l'app parte e non
#      trova i suoi shader, e la pulizia AI fallisce a runtime senza un errore in build.
#   2. **i bundle di risorse SwiftPM si copiano in `Contents/Resources/`**, non accanto
#      all'eseguibile: in un `.app` si risolvono via `Bundle.main.resourceURL`.
#   3. **l'Info.plist è committato** (`Sources/Kalamos/Resources/Kalamos-Info.plist`) e porta le
#      descrizioni d'uso del microfono e degli AppleEvents. Generarne uno le perderebbe, e l'app
#      non potrebbe più chiedere il microfono.
#   4. **l'app viva si chiude e si riapre**, perché `open` su un'app della barra dei menu già viva
#      porta in primo piano l'istanza vecchia in memoria: si proverebbe una build stale.
#
# L'interfaccia di prima è intatta, perché la usa la CI:
#   Scripts/build-app.sh [Debug|Release]
#   KALAMOS_VERSION=1.5.1   KALAMOS_NO_INSTALL=1
#
# Ritorno indietro: `git checkout pre-arche-20260826 -- Scripts/build-app.sh`
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHE="${ARCHE_TOOLS:-$HOME/.claude/skills/Arche/Tools}"
CONFIG="${1:-Debug}"

export ARCHE_KALAMOS_CONFIG="$CONFIG"
export ARCHE_KALAMOS_PRODUCTS="$ROOT/.build/xc/Build/Products/$CONFIG"

ARGS=(
    --root "$ROOT"
    --nome Kalamos
    --dest "$ROOT/build"
    --comando-build "bash \"$ROOT/Scripts/arche-xcodebuild.sh\" \"$CONFIG\""
    --binario "$ARCHE_KALAMOS_PRODUCTS/Kalamos"
    --plist-file "$ROOT/Sources/Kalamos/Resources/Kalamos-Info.plist"
    --bundle-id com.kalamos.app
    --icona nessuna
    --lsui true
    --vivo riavvia
    --no-test
)

if [[ -n "${KALAMOS_VERSION:-}" ]]; then
    ARGS+=(--version "$KALAMOS_VERSION")
fi
if [[ -n "${KALAMOS_NO_INSTALL:-}" ]]; then
    ARGS+=(--no-install)
fi

exec bash "$ARCHE/BuildApp.sh" "${ARGS[@]}"
