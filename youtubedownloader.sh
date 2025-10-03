#!/usr/bin/env bash
set -euo pipefail

# Usage: ./youtubedownloader.sh "<YouTube playlist/watch URL>"
if [ $# -lt 1 ]; then
  echo "Usage: $0 <YouTube playlist or watch URL>"
  exit 1
fi

URL="$1"
OUTDIR="yt_playlist_downloads"
ARCHIVE="${OUTDIR}/archive.txt"
mkdir -p "$OUTDIR"

command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg missing"; exit 1; }

# Fresh yt-dlp (distro versions often break with YT changes)
mkdir -p bin
if ! ./bin/yt-dlp --version >/dev/null 2>&1; then
  echo "Getting latest yt-dlp..."
  curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o ./bin/yt-dlp
  chmod +x ./bin/yt-dlp
fi
YTDLP=./bin/yt-dlp

# Your Firefox (Snap) profile cookies
COOKIE_BROWSER=(--cookies-from-browser "firefox:/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default")

# Common flags (robust)
BASE_FLAGS=(
  --yes-playlist
  -i
  --no-abort-on-error
  --ignore-no-formats-error
  --skip-unavailable-fragments
  --socket-timeout 60
  --retries 10
  --fragment-retries 10
  --concurrent-fragments 5
  --download-archive "$ARCHIVE"
  --embed-metadata --add-metadata
  --force-ipv4
  --sleep-requests 1
  --match-filter "is_live!=1 & was_live!=1"
  --geo-bypass-country US
  --format "bestaudio[ext=m4a]/bestaudio/best"
  --extract-audio --audio-format mp3 --audio-quality 0
)

# Try multiple player clients to dodge SABR/403
CLIENTS=("android" "tvhtml5" "web")

bulk_success=false
for client in "${CLIENTS[@]}"; do
  echo ">> Trying client: $client (bulk playlist)…"
  if "$YTDLP" "${COOKIE_BROWSER[@]}" "${BASE_FLAGS[@]}" \
       --extractor-args "youtube:player_client=${client}" \
       -o "${OUTDIR}/%(playlist_index)s - %(title)s.%(ext)s" \
       "$URL"
  then
    bulk_success=true
    break
  else
    echo "⚠️  Bulk with client=${client} failed; will try next client…"
  fi
done

if "$bulk_success"; then
  echo "✅ Done! Files saved in: $OUTDIR"
  exit 0
fi

echo "⚠️  Bulk failed for all clients — falling back to per-video…"

# Get IDs once (use the most permissive client)
video_ids="$("$YTDLP" "${COOKIE_BROWSER[@]}" --flat-playlist --get-id "$URL" 2>/dev/null || true)"
if [ -z "${video_ids//[$'\t\r\n ']/}" ]; then
  echo "❌ Could not fetch playlist items. Make sure that Firefox profile is signed in."
  exit 1
fi

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
