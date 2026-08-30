#!/bin/bash
# Il riavvio vero si misura a mano sul bundle installato. Questa sonda ferma il giro prima di
# riaprire se stessa e copre i tre percorsi con uno shim locale di Homebrew.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.build/debug/Kalamos"

if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != "--binario" ]]; then
        echo "uso: Scripts/bench-updates.sh [--binario path/to/Kalamos]" >&2
        exit 2
    fi
    BINARY="$2"
fi

if [[ ! -x "$BINARY" ]]; then
    echo "binario non eseguibile: $BINARY" >&2
    exit 2
fi

BENCH="$(mktemp -d "${TMPDIR:-/tmp}/kalamos-updates.XXXXXX")"
export BENCH
trap 'rm -rf "$BENCH"' EXIT

SHIM="$BENCH/brew"
RELEASE="$BENCH/release.json"
CASKROOM="$BENCH/Caskroom"
mkdir -p "$BENCH/not-a-git-repository" "$CASKROOM/kalamos"

cat > "$SHIM" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$BENCH/brew.log"
if [[ "${1:-}" == "--repository" ]]; then
    printf '%s\n' "$BENCH/not-a-git-repository"
    exit 0
fi
printf '%s\n' "fake Homebrew: preparo Kalamos" "fake Homebrew: aggiornamento finito"
SH
chmod +x "$SHIM"
printf '%s\n' '{"tag_name":"v9.9.9","draft":false}' > "$RELEASE"

run_probe() {
    local caskroom="$1"
    local brew="$2"
    env KALAMOS_BREW="$brew" \
        KALAMOS_CASKROOM="$caskroom" \
        KALAMOS_UPDATES_API="file://$RELEASE" \
        "$BINARY" --bench-updates 2>&1
}

rm -f "$BENCH/brew.log"
brew_output="$(run_probe "$CASKROOM" "$SHIM")"
printf '%s\n' "$brew_output"
[[ -f "$BENCH/brew.log" ]]
[[ "$(grep -Fxc -- '--repository xmasyx/tap' "$BENCH/brew.log")" -eq 1 ]]
[[ "$(grep -Fxc -- 'upgrade --cask xmasyx/tap/kalamos' "$BENCH/brew.log")" -eq 1 ]]
[[ "$(wc -l < "$BENCH/brew.log" | tr -d ' ')" -eq 2 ]]

rm -f "$BENCH/brew.log"
manual_output="$(run_probe "" "$SHIM")"
printf '%s\n' "$manual_output"
[[ ! -s "$BENCH/brew.log" ]]
grep -Fq -- 'openReleasePage https://github.com/xmasyx/kalamos/releases/tag/v9.9.9' \
    <<< "$manual_output"

rm -f "$BENCH/brew.log"
missing_output="$(run_probe "$CASKROOM" /nonexistent)"
printf '%s\n' "$missing_output"
grep -Fq -- 'failed' <<< "$missing_output"
grep -Fq -- 'openReleasePage https://github.com/xmasyx/kalamos/releases/tag/v9.9.9' \
    <<< "$missing_output"

echo "✓ banco aggiornamenti: Homebrew, manuale e Homebrew assente"
