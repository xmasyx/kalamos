#!/usr/bin/env bash
# Turns a screen recording into the looping GIF the README shows at the top.
#
#   ./Scripts/make-readme-gif.sh ~/Desktop/wave.mov docs/wave.gif
#
# Records are expected to be short (6-10 s) and cropped to the thing that moves:
# a 620px-wide GIF of the whole screen is unreadable, and a 40 MB one never loads.
# The palette pass is what keeps a gradient waveform from banding into mush.
set -euo pipefail

SRC="${1:?usage: make-readme-gif.sh <recording.mov> [output.gif]}"
OUT="${2:-docs/wave.gif}"
WIDTH="${WIDTH:-620}"
FPS="${FPS:-20}"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such recording: $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ffmpeg -v error -i "$SRC" \
  -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$TMP/palette.png"

ffmpeg -v error -i "$SRC" -i "$TMP/palette.png" \
  -lavfi "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 -y "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
echo "$OUT — $SIZE"
# GitHub renders inline up to ~10 MB, but anything past ~3 MB is a slow README.
# If it is bigger: cut the recording shorter, or drop FPS to 15.
