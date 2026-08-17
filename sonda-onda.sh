#!/bin/bash
# sonda-onda.sh — l'onda e l'isola, guardate e MISURATE.
#
# Perché esiste. Tre dei quattro difetti visti sul campo il 2026-08-16 sono
# difetti che una prova non prende e una fotografia non racconta: la forma
# dell'isoletta si giudica a occhio, la risposta dell'onda alla voce è un
# rapporto fra due numeri, e la discesa della goccia è un movimento. Questa sonda
# produce, in un colpo solo, gli artefatti su cui quei tre giudizi si possono
# davvero dare — e i cancelli che dicono se gli artefatti valgono qualcosa.
#
# Che cosa fa, in ordine:
#   1. compila e gira la suite;
#   2. misura la risposta dell'onda al livello (cancello: ≥ 2×);
#   3. fotografa la pillola e la pagina Onda delle impostazioni, nelle DUE facce;
#   4. gira i filmati dell'isola, notch e pillola;
#   5. misura i filmati fotogramma per fotogramma e stampa la firma della discesa;
#   6. otto cancelli sui pixel, contati e riportati.
#
# **I cancelli sono sui PIXEL e non sui percorsi.** `screencapture` esce 0 senza
# scrivere niente quando manca il permesso di registrazione dello schermo, e una
# sonda che stampa un percorso senza guardare il file è la sonda che ha già
# ingannato questo progetto una volta (ISA, 2026-08-06). Qui ogni artefatto viene
# riaperto e misurato.
#
# Le finestre compaiono davvero, per qualche secondo: è voluto: ciò che il
# window server compone non è ciò che una vista disegna per sé.
set -uo pipefail
cd "$(dirname "$0")"

OUT="${1:-docs/sonda-onda}"
BIN=".build/debug/Kalamos"
mkdir -p "$OUT"

verde=0; rosso=0
cancello() {   # cancello <nome> <condizione già valutata: 0/1> <dettaglio>
  if [ "$2" -eq 0 ]; then
    printf '  ✓ %-42s %s\n' "$1" "$3"; verde=$((verde + 1))
  else
    printf '  ✗ %-42s %s\n' "$1" "$3"; rosso=$((rosso + 1))
  fi
}

# Larghezza e altezza di un PNG, senza dipendenze: `sips` è di sistema.
misura_png() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null |
    awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w" "h}'
}

echo "── 1. compilazione e prove ────────────────────────────────────────────"
swift build 2>&1 | grep -E '^.*error' && { echo "compilazione fallita"; exit 1; }
PROVE=$(swift test 2>&1 | tail -3 | grep -E 'Test run')
echo "  $PROVE"
echo "$PROVE" | grep -q "passed" ; cancello "la suite passa" $? "$PROVE"

echo
echo "── 2. l'onda risponde alla voce ───────────────────────────────────────"
"$BIN" --misura-onda | sed 's/^/  /'
RAPPORTO=$?
cancello "banda a 0,7 almeno doppia di quella a 0,1" $RAPPORTO "misurato da MisuraMoto"

echo
echo "── 3. fotografie, le due facce ────────────────────────────────────────"
for faccia in light dark; do
  rm -f "$OUT/pillola-$faccia.png" "$OUT/impostazioni-onda-$faccia.png" \
        "$OUT/impostazioni-notch-$faccia.png"
  "$BIN" --scatta="$OUT/pillola-$faccia.png" --isola=bolla --livello=0.6 "--$faccia" >/dev/null 2>&1
  rm -f "$OUT/notch-$faccia.png"
  "$BIN" --scatta="$OUT/notch-$faccia.png" --isola=notch --livello=0.6 "--$faccia" >/dev/null 2>&1
  FILO=$("$BIN" --misura-filo="$OUT/notch-$faccia.png" 2>&1); ESITO=$?
  cancello "il filo tocca i bordi nel notch ($faccia)" $ESITO "$(echo "$FILO" | head -1)"
  # La pagina Onda nelle DUE anteprime: quella che mostra la pillola è la sola
  # in cui si vede la forma nuova, e senza `--anteprima` si fotografava sempre
  # e solo la banda del notch, cioè l'unica delle due che non è cambiata.
  "$BIN" --scatta="$OUT/impostazioni-onda-$faccia.png" --sezione=wave --anteprima=bolla "--$faccia" >/dev/null 2>&1
  "$BIN" --scatta="$OUT/impostazioni-notch-$faccia.png" --sezione=wave --anteprima=notch "--$faccia" >/dev/null 2>&1

  for nome in pillola impostazioni-onda impostazioni-notch; do
    f="$OUT/$nome-$faccia.png"
    if [ -s "$f" ]; then
      dim=$(misura_png "$f")
      # Una fotografia più piccola di 200 pixel di lato non è una finestra: è
      # quello che esce quando la finestra non c'era e si è scattato un residuo.
      w=$(echo "$dim" | cut -d' ' -f1)
      [ "${w:-0}" -ge 200 ]
      cancello "$nome-$faccia scattata" $? "$dim pixel"
      # Il filo da bordo a bordo, misurato sul pixel (sua fotografia del
      # 2026-08-16: «le estremità dovrebbero essere connesse ai bordi»). Solo
      # sull'isola: nella pagina delle impostazioni il soggetto è la pagina.
      if [ "$nome" = pillola ]; then
        FILO=$("$BIN" --misura-filo="$f" 2>&1); ESITO=$?
        cancello "il filo tocca i bordi ($faccia)" $ESITO "$(echo "$FILO" | head -1)"
      fi
    else
      cancello "$nome-$faccia scattata" 1 "nessun file — permesso schermo?"
    fi
  done
done

echo
echo "── 4. filmati, entrata e uscita ───────────────────────────────────────"
for posizione in notch bolla; do
  mov="$OUT/isola-$posizione.mov"
  rm -f "$mov"
  "$BIN" --isola-filmato="$mov" --isola=$posizione --livello=0.6 --light >/dev/null 2>&1
  [ -s "$mov" ]
  cancello "filmato $posizione girato" $? "$( [ -s "$mov" ] && du -h "$mov" | cut -f1 || echo assente )"
done

echo
echo "── 5. i filmati, misurati ─────────────────────────────────────────────"
for posizione in notch bolla; do
  mov="$OUT/isola-$posizione.mov"
  [ -s "$mov" ] || continue
  echo "  ▸ $posizione"
  # Solo il notch è giudicato come goccia: la pillola entra in dissolvenza, e
  # pretendere da lei la stessa firma vorrebbe dire chiedere a un'entrata di
  # essere quella che non è.
  if [ "$posizione" = notch ]; then
    "$BIN" --misura-filmato="$mov" --goccia > "$OUT/misura-$posizione.txt" 2>&1
    GOCCIA=$?
  else
    "$BIN" --misura-filmato="$mov" > "$OUT/misura-$posizione.txt" 2>&1
    GOCCIA=""
  fi
  tail -3 "$OUT/misura-$posizione.txt" | sed 's/^/    /'
  if [ -n "$GOCCIA" ]; then
    cancello "la discesa dal notch è una goccia" "$GOCCIA" \
      "$(grep -o 'la larghezza tiene [^;]*' "$OUT/misura-$posizione.txt" | head -1)"
  fi
  # Un filmato in cui NESSUN fotogramma contiene l'isola è un filmato della
  # carta e basta: succede quando la finestra non arriva in tempo, ed è
  # indistinguibile da un filmato riuscito se si guarda solo la dimensione.
  VUOTI=$(grep -o 'fotogrammi senza isola: [0-9]*' "$OUT/misura-$posizione.txt" | grep -o '[0-9]*' | head -1)
  TOT=$(grep -o 'su [0-9]*' "$OUT/misura-$posizione.txt" | grep -o '[0-9]*' | head -1)
  [ -n "${VUOTI:-}" ] && [ -n "${TOT:-}" ] && [ "$VUOTI" -lt "$TOT" ]
  cancello "il filmato $posizione contiene l'isola" $? "${VUOTI:-?} fotogrammi vuoti su ${TOT:-?}"
done

echo
echo "── 5b. l'isola resta al posto suo cambiando schermata ─────────────────"
# Il secondo difetto del 16/08: «quando passo da una schermata all'altra, il notch
# resti persistente con l'onda che va, e non che compaia e scompaia».
#
# **Non apre finestre**: costruisce il pannello vero e ne rilegge i permessi.
# La sonda porta il proprio polo negativo dentro di sé — toglie `stationary` alla
# finestra viva e pretende di accorgersene — quindi qui basta il suo codice
# d'uscita. La conferma dello swipe vero resta un gesto delle sue mani.
"$BIN" --sonda-pannello > "$OUT/pannello.txt" 2>&1
ESITO=$?
sed 's/^/    /' "$OUT/pannello.txt"
cancello "l'isola sta su tutte le scrivanie" $ESITO \
  "$(grep -o 'comportamento: \[[^]]*\]' "$OUT/pannello.txt" | head -1)"

echo
echo "── 6. il pompaggio, e il suo polo negativo ────────────────────────────"
# Il difetto del 2026-08-16: «si muove troppo troppo troppo, vibra tanto ed è
# fastidioso a vedersi». È un difetto che vive FRA i fotogrammi e DENTRO il
# guscio: la misura della sezione 5 segue l'ingombro dell'isola, che è la
# pillola, e la pillola non cambia mai — un'onda piena e un'onda collassata a una
# riga le danno lo stesso numero.
#
# Il filmato gira con un parlato SCRITTO (raffiche a 150 ms, stacchi di parola da
# 450 ms), così è lo stesso a ogni ripresa e nessun microfono si apre.
#
# **La seconda ripresa è il polo negativo, e senza di essa la prima non prova
# niente**: le stesse raffiche con la taratura della mattina del 16/08 DEVONO
# fallire il primo criterio. Se un giorno passasse, vorrebbe dire che il banco ha
# smesso di vedere la vibrazione che lui vedeva.
for taratura in viva prima; do
  mov="$OUT/pompaggio-$taratura.mov"
  rm -f "$mov"
  if [ "$taratura" = prima ]; then FLAG=--taratura=prima; else FLAG=; fi
  "$BIN" --isola-filmato="$mov" --isola=bolla --profilo-parlato $FLAG --light >/dev/null 2>&1
  [ -s "$mov" ]
  cancello "filmato del parlato girato ($taratura)" $? \
    "$( [ -s "$mov" ] && du -h "$mov" | cut -f1 || echo assente )"
  [ -s "$mov" ] || continue
  "$BIN" --misura-pompaggio="$mov" > "$OUT/pompaggio-$taratura.txt" 2>&1
  ESITO=$?
  sed 's/^/    /' "$OUT/pompaggio-$taratura.txt"
  TENUTA=$(grep -o 'min/max [0-9.]*' "$OUT/pompaggio-$taratura.txt" | head -1)
  if [ "$taratura" = viva ]; then
    cancello "l'onda non pompa più" $ESITO "$TENUTA"
  else
    # Il verso è INVERTITO di proposito: qui il verde è il rosso della misura.
    #
    # **Ma non basta «è fallita»**, e questo cancello ha già mentito una volta
    # (19:05 del 16/08): la ripresa era morta a 82 fotogrammi su 330, la misura
    # era uscita 4 — «filmato non misurabile» — e un cancello che accettava
    # qualunque codice diverso da zero l'ha letta come «ecco, pompa». Un polo
    # negativo che si accontenta di un guasto qualunque resta verde anche quando
    # il banco non ha misurato niente, cioè proprio quando non vale niente.
    #
    # Servono due cose insieme: il codice 6, che è «i criteri sono stati valutati
    # e almeno uno è rosso», e il criterio 1 rosso chiamato per nome. Il 4,
    # ripresa inservibile, adesso è rosso da questa parte come dall'altra.
    [ "$ESITO" -eq 6 ] && grep -q '✗ 1 · non collassa' "$OUT/pompaggio-$taratura.txt"
    cancello "la taratura di prima pompa (polo negativo)" $? \
      "${TENUTA:-misura non riuscita, codice $ESITO}"
  fi
done

echo
echo "── cancelli ───────────────────────────────────────────────────────────"
echo "  $verde/$((verde + rosso))"
echo "  artefatti in $OUT"
[ "$rosso" -eq 0 ]
