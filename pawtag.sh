#!/usr/bin/env bash
set -euo pipefail

# PawTagger FAST (standalone)
# Tag existing MP3/M4A files using YouTube playlist metadata.
# - No downloading of media
# - No renaming of files
# - Parallel metadata fetch + on-disk cache
#
# Usage:
#   ./pawtag.sh --folder "yt_playlist_downloads" \
#               --playlist "https://www.youtube.com/playlist?list=XXXX" \
#               [--album "YouTube: My Mix"] [--workers 8] [--no-cover] [--no-year] [--dry-run] \
#               [--ff-profile "/path/to/firefox/profile"] [--ytdlp "./bin/yt-dlp"]
#
# Defaults:
#   --ff-profile "$HOME/snap/firefox/common/.mozilla/firefox/*default*"
#   --ytdlp "./bin/yt-dlp" (auto-downloads if missing)

# ---------- pretty logs ----------
BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
say(){ printf "%b\n" "$*${RESET}"; }

# ---------- args ----------
FOLDER=""
PLAYLIST=""
# sensible default for Snap Firefox; override with --ff-profile
FF_PROFILE_DEFAULT="$(printf "%s" "$HOME/snap/firefox/common/.mozilla/firefox"/*default* 2>/dev/null || true)"
FF_PROFILE="${FF_PROFILE:-${FF_PROFILE_DEFAULT:-$HOME/.mozilla/firefox}}"
YTDLP="${YTDLP:-./bin/yt-dlp}"
ALBUM_OVERRIDE=""
WORKERS=8
NO_COVER=0
NO_YEAR=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --folder)     FOLDER="${2:-}"; shift 2;;
    --playlist)   PLAYLIST="${2:-}"; shift 2;;
    --ff-profile) FF_PROFILE="${2:-}"; shift 2;;
    --ytdlp)      YTDLP="${2:-}"; shift 2;;
    --album)      ALBUM_OVERRIDE="${2:-}"; shift 2;;
    --workers)    WORKERS="${2:-8}"; shift 2;;
    --no-cover)   NO_COVER=1; shift;;
    --no-year)    NO_YEAR=1; shift;;
    --dry-run)    DRY=1; shift;;
    -h|--help)
      cat <<EOF
${BOLD}PawTagger FAST${RESET}
Tags existing MP3/M4A files by playlist index using YouTube metadata.

Required:
  --folder <dir>        Folder with files like '001 - Title.mp3'
  --playlist <url>      YouTube playlist URL (maps 001->index 1, etc.)

Options:
  --album "<name>"      Force album name (skip title fetch)
  --workers <N>         Parallel metadata workers (default: 8)
  --no-cover            Skip cover images (faster)
  --no-year             Skip upload-year tagging (faster)
  --dry-run             Log actions; don't write tags
  --ff-profile <dir>    Firefox profile for cookies (default: $FF_PROFILE)
  --ytdlp <path>        Path to yt-dlp (default: $YTDLP; auto-downloads)
EOF
      exit 0;;
    *) say "${YELLOW}Unknown arg:${RESET} $1"; exit 1;;
  esac
done

[ -n "$FOLDER" ]   || { say "${RED}Missing --folder${RESET}"; exit 1; }
[ -n "$PLAYLIST" ] || { say "${RED}Missing --playlist${RESET}"; exit 1; }
[ -d "$FOLDER" ]   || { say "${RED}Folder not found:${RESET} $FOLDER"; exit 1; }

say "${BOLD}🐾 PawTagger FAST${RESET}"
say "📂 ${BOLD}Folder:${RESET}   $FOLDER"
say "🎶 ${BOLD}Playlist:${RESET} $PLAYLIST"
say "🍪 ${BOLD}Firefox:${RESET}  $FF_PROFILE"
say "🧰 ${BOLD}yt-dlp:${RESET}    $YTDLP"
say "🚀 ${BOLD}Workers:${RESET}  $WORKERS | Cover: $([ $NO_COVER -eq 1 ] && echo off || echo on) | Year: $([ $NO_YEAR -eq 1 ] && echo off || echo on) | Dry: $([ $DRY -eq 1 ] && echo True || echo False)"

# ---------- ensure yt-dlp ----------
if [ ! -x "$YTDLP" ]; then
  say "⬇️  Fetching latest yt-dlp to ${YTDLP}…"
  mkdir -p "$(dirname "$YTDLP")"
  if command -v curl >/dev/null 2>&1; then
    curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$YTDLP"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  else
    say "${RED}Need curl or wget to fetch yt-dlp${RESET}"; exit 1;
  fi
  chmod +x "$YTDLP"
fi

# ---------- ensure mutagen ----------
if ! python3 -c 'import mutagen' >/dev/null 2>&1; then
  say "📦 Installing Python 'mutagen'…"
  python3 -m pip install --user mutagen >/dev/null
fi

# ---------- run tagger (Python) ----------
python3 - "$FOLDER" "$PLAYLIST" "$YTDLP" "$FF_PROFILE" "$ALBUM_OVERRIDE" "$WORKERS" "$NO_COVER" "$NO_YEAR" "$DRY" <<'PY'
import sys, json, subprocess, tempfile, os, re, urllib.request, time, concurrent.futures
from pathlib import Path
from datetime import datetime

folder, playlist_url, ytdlp, ff_profile, album_override, workers, no_cover, no_year, dry = sys.argv[1:]
workers = int(workers); no_cover = int(no_cover); no_year = int(no_year); dry = int(dry)

def log(m): print(m, flush=True)

def run(cmd, timeout=None):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or '').strip() or "command failed")
    return p.stdout

# ---------- cache ----------
CACHE = Path(".pawtag_cache.json")
cache = {}
if CACHE.exists():
    try: cache = json.loads(CACHE.read_text(encoding="utf-8"))
    except Exception: cache = {}
def save_cache():
    try: CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception: pass

# ---------- playlist JSON with timeouts + fallbacks ----------
log("📖 Fetching playlist JSON once (-J)…")
def ytdlp_json_with_timeout(args, timeout=25):
    out = run(args, timeout=timeout)
    return json.loads(out)

pl_json = None
errors = []

# A) web client + cookies
try:
    pl_json = ytdlp_json_with_timeout([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                                       "--extractor-args","youtube:player_client=web","-J",playlist_url], timeout=25)
except Exception as e: errors.append(f"A(web+cookies): {e}")

# B) android client + cookies
if pl_json is None:
    try:
        pl_json = ytdlp_json_with_timeout([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                                           "--extractor-args","youtube:player_client=android","-J",playlist_url], timeout=25)
    except Exception as e: errors.append(f"B(android+cookies): {e}")

# C) web client no-cookies
if pl_json is None:
    try:
        pl_json = ytdlp_json_with_timeout([ytdlp,"--extractor-args","youtube:player_client=web",
                                           "-J",playlist_url], timeout=20)
    except Exception as e: errors.append(f"C(web no-cookies): {e}")

idx_map = {}
album = album_override or None

if pl_json is None:
    # D) flat fallback
    log("⚠️  -J failed; falling back to flat index map…")
    try:
        flat = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                    "--flat-playlist","--print","%(playlist_index)s\t%(id)s\t%(title)s",playlist_url], timeout=25)
    except Exception as e:
        log("❌ Could not build index map from flat playlist.")
        for er in errors: log("   " + er)
        sys.exit(1)
    for line in flat.splitlines():
        parts = line.strip().split("\t", 3)
        if len(parts) >= 2 and parts[0].isdigit():
            idx_map[int(parts[0])] = {"id": parts[1], "yt_title": parts[2] if len(parts)>2 else None}
    if not idx_map:
        log("❌ Flat playlist contained no entries.")
        for er in errors: log("   " + er)
        sys.exit(1)
    if album is None: album = "YouTube Playlist"
else:
    entries = pl_json.get("entries") or []
    for e in entries:
        try:
            idx = int(e.get("playlist_index") or 0)
            if idx > 0:
                idx_map[idx] = {"id": e.get("id"), "yt_title": e.get("title")}
        except Exception:
            pass
    if not idx_map:
        log("🫥 No entries found in playlist JSON.")
        for er in errors: log("   " + er)
        sys.exit(1)
    if album is None: album = f"YouTube: {pl_json.get('title') or 'Playlist'}"

log("="*72 + f"\n🎵 Now tagging album: {album}\n" + "="*72)

# ---------- gather files ----------
folder = Path(folder).expanduser().resolve()
rx = re.compile(r"^(\d{3})\s*-\s*.+\.(mp3|m4a)$", re.IGNORECASE)
files = sorted([p for p in folder.iterdir() if p.is_file() and rx.match(p.name)])
if not files:
    log("🫥 No files matching 'NNN - *.mp3/m4a'."); sys.exit(0)
log(f"🔍 Found {len(files)} file(s) to process.")

# ---------- figure which video IDs we must fetch ----------
needed = []
file_infos = []  # (path, idx, ext, vid, yt_title)
for f in files:
    m = rx.match(f.name); idx = int(m.group(1)); ext = m.group(2).lower()
    ent = idx_map.get(idx)
    if not ent or not ent.get("id"):
        log(f"[skip] No playlist entry for index {idx:03d} → {f.name}")
        continue
    vid = ent["id"]
    file_infos.append((f, idx, ext, vid, ent.get("yt_title")))
    if vid not in cache:
        needed.append(vid)

log(f"🗂️  Cache: {len(cache)} entries | Need fetch: {len(needed)}")

# ---------- parallel metadata fetch ----------
def try_clients_get_json(url, clients=("android","tvhtml5","web")):
    last=None
    for c in clients:
        try:
            out = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                       "--extractor-args",f"youtube:player_client={c}","-j",url], timeout=25)
            return json.loads(out)
        except Exception as e: last=e
    raise last

def best_thumb(ts):
    if not ts: return None
    return max(ts, key=lambda t: t.get("height",0)).get("url")

def fetch_one(vid):
    url = f"https://www.youtube.com/watch?v={vid}"
    try:
        info = try_clients_get_json(url)
        data = {
            "title": info.get("title"),
            "uploader": info.get("uploader") or info.get("channel"),
            "upload_date": info.get("upload_date"),
            "thumbnail": best_thumb(info.get("thumbnails") or [])
        }
        return vid, data, None
    except Exception as e:
        return vid, None, str(e)

if needed:
    log(f"⚡ Fetching metadata for {len(needed)} video(s) with {workers} workers…")
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for vid, data, err in ex.map(fetch_one, needed):
            if data: cache[vid] = data
            else: log(f"   ⚠️  {vid} metadata failed: {err}")
    save_cache()

# ---------- cover downloader ----------
def dl_thumb(u):
    if not u or no_cover: return None
    try:
        fd, path = tempfile.mkstemp(prefix="pawtag_", suffix=".jpg"); os.close(fd)
        urllib.request.urlretrieve(u, path)
        return path
    except Exception: return None

# ---------- taggers ----------
def tag_mp3(path, meta, cover):
    from mutagen.id3 import ID3, APIC, TIT2, TPE1, TALB, TRCK, TDRC, COMM
    try: tags = ID3(path)
    except Exception: tags = ID3()
    if meta.get("title"):  tags.add(TIT2(encoding=3,text=meta["title"]))
    if meta.get("artist"): tags.add(TPE1(encoding=3,text=meta["artist"]))
    if meta.get("album"):  tags.add(TALB(encoding=3,text=meta["album"]))
    if meta.get("track"):  tags.add(TRCK(encoding=3,text=str(meta["track"])))
    if meta.get("year") and not no_year: tags.add(TDRC(encoding=3,text=str(meta["year"])))
    c = (meta.get("url") or "") + (f" (id={meta.get('id')})" if meta.get("id") else "")
    if c.strip(): tags.add(COMM(encoding=3,desc="comment",text=c.strip()))
    if cover:
        with open(cover,"rb") as f: data=f.read()
        tags.add(APIC(encoding=3,mime="image/jpeg",type=3,desc="Cover",data=data))
    tags.save(path)

def tag_m4a(path, meta, cover):
    from mutagen.mp4 import MP4, MP4Cover
    a = MP4(path)
    if meta.get("title"):  a["\xa9nam"]=meta["title"]
    if meta.get("artist"): a["\xa9ART"]=meta["artist"]
    if meta.get("album"):  a["\xa9alb"]=meta["album"]
    if meta.get("track"):  a["trkn"]=[(int(meta["track"]),0)]
    if meta.get("year") and not no_year: a["\xa9day"]=str(meta["year"])
    if meta.get("url"):    a["----:com.apple.iTunes:url"]=[meta["url"].encode()]
    if meta.get("id"):     a["----:com.apple.iTunes:youtube_id"]=[meta["id"].encode()]
    if cover:
        with open(cover,"rb") as f: data=f.read()
        a["covr"]=[MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG)]
    a.save()

# ---------- tag loop ----------
for f, idx, ext, vid, yt_title in file_infos:
    url = f"https://www.youtube.com/watch?v={vid}"
    data = cache.get(vid, {})
    title  = data.get("title") or yt_title or f.name
    artist = data.get("uploader") or "YouTube"
    year = None
    if not no_year:
        up = data.get("upload_date")
        if isinstance(up, str) and len(up)==8:
            try: year = datetime.strptime(up, "%Y%m%d").year
            except Exception: year = None
    cover_path = dl_thumb(data.get("thumbnail"))

    print(f"[{idx:03d}] {f.name}")
    print(f"      title:  {title}")
    print(f"      artist: {artist}")
    print(f"      album:  {album}")
    print(f"      track#: {idx}")
    print(f"      year:   {year if year is not None else ('(skipped)' if no_year else 'unknown')}")
    print(f"      id/url: {vid}  {url}")
    print(f"      cover:  {'yes → ' + Path(cover_path).name if cover_path else ('(skipped)' if no_cover else 'no')}")

    if dry:
        if cover_path and os.path.exists(cover_path): os.remove(cover_path)
        continue

    try:
        meta = {"title":title,"artist":artist,"album":album,"track":idx,"year":year,"url":url,"id":vid}
        if ext == "mp3": tag_mp3(str(f), meta, cover_path)
        else:            tag_m4a(str(f), meta, cover_path)
        print("   ✅ tagged")
    finally:
        if cover_path and os.path.exists(cover_path): os.remove(cover_path)

print("🎉 Done.")
PY

say "${GREEN}✅ PawTagger finished.${RESET}"
