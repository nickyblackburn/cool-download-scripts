#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./youtubedownloader.sh "https://www.youtube.com/playlist?list=XXXX"
#
# Optional:
#   UPDATE=1 ./youtubedownloader.sh "<url>"   # force-refresh yt-dlp binary

if [ $# -lt 1 ]; then
  echo "Usage: $0 <YouTube playlist or watch URL>"
  exit 1
fi

URL="$1"

# --- paths & dirs ---
OUTDIR="yt_playlist_downloads"
ARCHIVE="${OUTDIR}/archive.txt"
BINDIR="./bin"
YTDLP="${BINDIR}/yt-dlp"
mkdir -p "$OUTDIR" "$BINDIR"
touch "$ARCHIVE"

# --- tools check ---
command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg missing"; exit 1; }
if command -v curl >/dev/null 2>&1; then DLTOOL="curl -L -o"; DLURL="curl -L"; else DLTOOL="wget -O"; DLURL="wget -qO-"; fi

# --- get fresh yt-dlp locally (self-contained) ---
if [ ! -x "$YTDLP" ] || [ "${UPDATE:-0}" = "1" ]; then
  echo "Getting latest yt-dlp..."
  $DLTOOL "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  chmod +x "$YTDLP"
fi

# --- your Firefox Snap profile cookies (already confirmed path) ---
FIREFOX_PROFILE="/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default"
COOKIE_BROWSER=(--cookies-from-browser "firefox:${FIREFOX_PROFILE}")

echo "🍪 Using Firefox cookies from: $FIREFOX_PROFILE"

# --- backfill archive from existing files with [VIDEOID].ext in name ---
# This prevents re-downloads even if filenames/templates change.
tmp_arch="$(mktemp)"
# Loop to be portable (no GNU find -printf dependency)
shopt -s nullglob
for f in "$OUTDIR"/*; do
  [ -f "$f" ] || continue
  base="$(basename -- "$f")"
  # match ...[VIDEOID].(mp3|m4a|webm|opus|mkv|mp4)
  if [[ "$base" =~ \[([A-Za-z0-9_-]{11})\]\.(mp3|m4a|webm|opus|mkv|mp4)$ ]]; then
    echo "youtube ${BASH_REMATCH[1]}" >>"$tmp_arch"
  fi
done
# merge + dedupe into ARCHIVE
cat "$ARCHIVE" "$tmp_arch" 2>/dev/null | awk 'NF' | sort -u > "${ARCHIVE}.new" && mv "${ARCHIVE}.new" "$ARCHIVE"
rm -f "$tmp_arch"

# --- common yt-dlp flags (robust) ---
BASE_FLAGS=(
  --yes-playlist
  -i
  --no-abort-on-error
  --ignore-no-formats-error
  --skip-unavailable-fragments
  --no-overwrites                   # skip if file path already exists
  --download-archive "$ARCHIVE"     # skip by video ID
  --socket-timeout 60
  --retries 10
  --fragment-retries 10
  --concurrent-fragments 5
  --embed-metadata --add-metadata
  --force-ipv4
  --sleep-requests 1
  --match-filter "is_live!=1 & was_live!=1"
  --geo-bypass-country US
  --format "bestaudio[ext=m4a]/bestaudio/best"
  --extract-audio --audio-format mp3 --audio-quality 0
)

# --- try multiple player clients to avoid SABR/403s ---
CLIENTS=("android" "tvhtml5" "web")

echo ">> Bulk playlist download …"
bulk_success=false
for client in "${CLIENTS[@]}"; do
  echo "   → trying client: ${client}"
  if "$YTDLP" "${COOKIE_BROWSER[@]}" "${BASE_FLAGS[@]}" \
       --extractor-args "youtube:player_client=${client}" \
       -o "${OUTDIR}/%(playlist_index)s - %(title)s.%(ext)s" \
       "$URL"
  then
    bulk_success=true
    break
  else
    echo "   ⚠️  bulk (client=${client}) failed; will try next…"
  fi
done

if "$bulk_success"; then
  echo "✅ Done! Files saved in: $OUTDIR"
  exit 0
fi

echo "⚠️  Bulk failed for all clients — falling back to per-video mode…"

# --- list video IDs once (no client arg needed here, but cookies still help) ---
video_ids="$("$YTDLP" "${COOKIE_BROWSER[@]}" --flat-playlist --get-id "$URL" 2>/dev/null || true)"
if [ -z "${video_ids//[$'\t\r\n ']/}" ]; then
  echo "❌ Could not fetch playlist items. Make sure that Firefox profile is signed in to YouTube."
  exit 1
fi

# --- per-video loop, trying clients in order; filenames include [id] for future backfills ---
while IFS= read -r vid; do
  [ -z "$vid" ] && continue
  vurl="https://www.youtube.com/watch?v=${vid}"
  echo ">> Downloading $vurl"
  ok=false
  for client in "${CLIENTS[@]}"; do
    if "$YTDLP" "${COOKIE_BROWSER[@]}" "${BASE_FLAGS[@]}" \
         --extractor-args "youtube:player_client=${client}" \
         -o "${OUTDIR}/%(title)s [%(id)s].%(ext)s" \
         "$vurl"
    then
      ok=true
      break
    else
      echo "   …client=${client} failed, trying next…"
    fi
  done
  $ok || echo "   ❌ Skipped $vurl (no playable formats with any client)"
done <<< "$video_ids"

echo "✅ Fallback complete. Files saved in: $OUTDIR"
