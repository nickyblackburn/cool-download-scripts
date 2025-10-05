#!/usr/bin/env bash
set -euo pipefail

# SoundCloud Downloader — MP3 with tags & cover
# Uses yt-dlp + ffmpeg. Skips already-downloaded tracks via archive.txt
#
# Usage examples:
#   ./soundcloud_downloader.sh "https://soundcloud.com/artist/track"
#   ./soundcloud_downloader.sh "https://soundcloud.com/artist/sets/my-playlist"
#   ./soundcloud_downloader.sh "https://soundcloud.com/you/likes"
#
# Options (env vars):
#   OUT_DIR=yt_downloaded              # output folder
#   ARCHIVE_FILE=archive.txt           # download-archive file location
#   COOKIES_FROM_FIREFOX=1             # use Firefox cookies (optional)
#   FIREFOX_PROFILE="$HOME/snap/firefox/common/.mozilla/firefox/xxxx.default"
#   MIN_SLEEP=0.8 MAX_SLEEP=2.0        # polite pacing between items
#   YTDLP=./bin/yt-dlp                 # custom yt-dlp path (auto-downloaded if missing)
#
# Notes:
#   • Please only download content you own or that is licensed for free use
#     (e.g., tracks with CC licenses or explicit permission).

# ---------- config defaults ----------
OUT_DIR="${OUT_DIR:-sc_downloads}"
ARCHIVE_FILE="${ARCHIVE_FILE:-$OUT_DIR/archive.txt}"
MIN_SLEEP="${MIN_SLEEP:-0.8}"
MAX_SLEEP="${MAX_SLEEP:-2.0}"
YTDLP="${YTDLP:-./bin/yt-dlp}"
COOKIES_FROM_FIREFOX="${COOKIES_FROM_FIREFOX:-0}"
FIREFOX_PROFILE="${FIREFOX_PROFILE:-$HOME/snap/firefox/common/.mozilla/firefox}"

# ---------- pretty logs ----------
BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; DIM="\033[2m"; RESET="\033[0m"
say(){ printf "%b\n" "$*${RESET}"; }

# ---------- args ----------
if [ $# -lt 1 ]; then
  say "${BOLD}SoundCloud Downloader${RESET}"
  echo "Usage: $0 <soundcloud-url>"
  exit 1
fi
RAW_URL="$1"

# ---------- URL sanitize (fix pasted \? \= etc & decode % encodings) ----------
SAFE_URL="${RAW_URL//\\?/?}"
SAFE_URL="${SAFE_URL//\\=/=}"
SAFE_URL="${SAFE_URL//\\&/&}"
if [[ "$SAFE_URL" == *%5C* || "$SAFE_URL" == *%3F* || "$SAFE_URL" == *%3D* || "$SAFE_URL" == *%26* ]]; then
  if command -v python3 >/dev/null 2>&1; then
    SAFE_URL="$(python3 - <<'PY' <<<"$SAFE_URL"
import sys, urllib.parse
print(urllib.parse.unquote(sys.stdin.read().strip()))
PY
)"
  fi
fi
SAFE_URL="${SAFE_URL//\\//}"

# final sanity
if [[ "$SAFE_URL" != https://soundcloud.com/* && "$SAFE_URL" != http://soundcloud.com/* ]]; then
  say "${RED}ERROR:${RESET} Not a SoundCloud URL: $SAFE_URL"
  exit 1
fi

URL="$SAFE_URL"

# ---------- ensure yt-dlp ----------
if [ ! -x "$YTDLP" ]; then
  say "⬇️  Getting latest yt-dlp → ${YTDLP}"
  mkdir -p "$(dirname "$YTDLP")"
  if command -v curl >/dev/null 2>&1; then
    curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$YTDLP"
  else
    wget -O "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  fi
  chmod +x "$YTDLP"
fi

# ---------- ensure ffmpeg ----------
if ! command -v ffmpeg >/dev/null 2>&1; then
  say "${RED}ERROR:${RESET} ffmpeg is required for audio extraction. Install it (e.g., 'sudo apt install ffmpeg')."
  exit 1
fi

# ---------- prepare output ----------
mkdir -p "$OUT_DIR"
mkdir -p "$(dirname "$ARCHIVE_FILE")"

say "${BOLD}🎧 SoundCloud Downloader${RESET}"
say "📂 Output:   $OUT_DIR"
say "📝 Archive:  $ARCHIVE_FILE"
say "🔗 URL:      $URL"
if [ "$COOKIES_FROM_FIREFOX" = "1" ]; then
  # choose first *default* profile if FIREFOX_PROFILE is a directory of profiles
  if [ -d "$FIREFOX_PROFILE" ] && [[ "$FIREFOX_PROFILE" != *".default"* && "$FIREFOX_PROFILE" != *".default-release"* ]]; then
    CANDIDATE="$(ls -d "$FIREFOX_PROFILE"/*default* 2>/dev/null | head -n1 || true)"
    [ -n "$CANDIDATE" ] && FIREFOX_PROFILE="$CANDIDATE"
  fi
  say "🍪 Cookies:  firefox:$FIREFOX_PROFILE"
else
  say "🍪 Cookies:  (none)"
fi

# ---------- polite pacing helper ----------
rand_sleep() {
  # random float between MIN_SLEEP and MAX_SLEEP
  python3 - <<PY 2>/dev/null || awk -v min="$MIN_SLEEP" -v max="$MAX_SLEEP" 'BEGIN{srand(); print min+rand()*(max-min)}'
import random, sys
minv=float(sys.argv[1]); maxv=float(sys.argv[2])
print(minv + random.random()*(maxv-minv))
PY
"$MIN_SLEEP" "$MAX_SLEEP"
}

# ---------- build yt-dlp command ----------
# Output template:
#   For playlists/sets: "NNN - Artist - Title.ext"
#   For single track:   "Artist - Title.ext"
OUT_TMPL_PLAYLIST="${OUT_DIR}/%(playlist_index|>03)s - %(uploader)s - %(title)s.%(ext)s"
OUT_TMPL_SINGLE="${OUT_DIR}/%(uploader)s - %(title)s.%(ext)s"

# Common flags:
COMMON_ARGS=(
  --ignore-config
  --no-warnings
  --no-overwrites
  --continue
  --force-ipv4
  --retries 3
  --fragment-retries 3
  --concurrent-fragments 4
  --buffer-size 4M
  --socket-timeout 20
  --sleep-requests "$(printf "%.2f" "$(rand_sleep)")"
  --max-sleep-interval "$(printf "%.0f" "$MAX_SLEEP")"
  --min-sleep-interval "$(printf "%.0f" "$MIN_SLEEP")"
  --download-archive "$ARCHIVE_FILE"
  --extract-audio
  --audio-format mp3
  --audio-quality 0               # best
  --embed-metadata
  --embed-thumbnail
  --add-metadata
)

# Use cookies if requested
if [ "$COOKIES_FROM_FIREFOX" = "1" ]; then
  COMMON_ARGS=(--cookies-from-browser "firefox:${FIREFOX_PROFILE}" "${COMMON_ARGS[@]}")
fi

# Detect if it's a set/playlist/profile likes
IS_PLAYLIST=0
if [[ "$URL" == *"/sets/"* ]] || [[ "$URL" == *"/likes" ]]; then
  IS_PLAYLIST=1
fi

say ">> Starting download…"
if [ $IS_PLAYLIST -eq 1 ]; then
  say "📜 Mode: playlist/set"
  "$YTDLP" \
    "${COMMON_ARGS[@]}" \
    --output "$OUT_TMPL_PLAYLIST" \
    --yes-playlist \
    --playlist-items "1-100000" \
    "$URL"
else
  say "🎵 Mode: single track (or will follow playlist automatically if provided)"
  "$YTDLP" \
    "${COMMON_ARGS[@]}" \
    --output "$OUT_TMPL_SINGLE" \
    "$URL"
fi

say "${GREEN}✅ Done.${RESET}"
echo
say "${DIM}Tip:${RESET} Run again later with the same archive.txt to only fetch new tracks."

