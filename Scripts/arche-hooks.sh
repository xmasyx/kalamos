#!/bin/bash
# Gli agganci di Kalamos dentro la consegna condivisa di Arche.

# ── I bundle di risorse SwiftPM, e l'icona committata
#
# In un `.app` i bundle di risorse SwiftPM si risolvono via `Bundle.main.resourceURL`, cioè da
# `Contents/Resources/` — NON accanto all'eseguibile. Dentro `mlx-swift_Cmlx.bundle` viaggia
# `default.metallib`, che è la ragione per cui questa app si compila con xcodebuild.
arche_bundle_extra() {
    local app="$1"
    local products="${ARCHE_KALAMOS_PRODUCTS:-}"
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    if [[ -n "$products" && -d "$products" ]]; then
        local n=0
        for b in "$products"/*.bundle; do
            [ -e "$b" ] || continue
            cp -R "$b" "$app/Contents/Resources/"
            n=$((n + 1))
        done
        echo "  $n bundle di risorse copiati in Contents/Resources"
    fi

    # L'icona è un asset committato, non un disegno rifatto a ogni build.
    if [[ -f "$root/Sources/Kalamos/Resources/AppIcon.icns" ]]; then
        cp "$root/Sources/Kalamos/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
        echo "  icona committata copiata"
    fi
}

# Il cancello che la CI aveva e la build locale no: un bundle senza `default.metallib` sembra sano
# finché qualcuno non accende la pulizia AI. Adesso ferma la consegna, non la release.
arche_pre_sign() {
    local app="$1"
    if [[ ! -f "$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
        echo "✘ default.metallib non è nel bundle: la pulizia AI fallirebbe a runtime" >&2
        exit 2
    fi
    echo "  default.metallib nel bundle"
}
