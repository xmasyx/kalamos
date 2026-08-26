#!/usr/bin/env bash
# Crea UNA VOLTA l'identità di firma stabile «Kalamos Dev» nel portachiavi di login.
#
# È un involucro: lo script vero è uno solo in Arche, e prima ce n'erano cinque copie divergenti
# nella famiglia — quattro identiche a meno del nome dell'identità, misurate il 2026-08-26.
# Tutte le ragioni e i gotcha (la partition list che blocca la prima firma dentro una build, i p12
# senza password che `security import` rifiuta) stanno lì, in un posto solo.
#
# Si esegue una volta sola, da un Terminale interattivo: la finestra del portachiavi deve poter
# comparire davvero.
#
# Ritorno indietro: `git checkout pre-arche-20260826 -- Scripts/make-signing-cert.sh`
set -euo pipefail
ARCHE="${ARCHE_TOOLS:-$HOME/.claude/skills/Arche/Tools}"
exec bash "$ARCHE/MakeSigningCert.sh" --nome "Kalamos" "$@"
