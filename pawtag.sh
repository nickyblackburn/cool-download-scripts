#!/usr/bin/env bash
set -euo pipefail

# PawTagger FAST — tags existing MP3/M4A by playlist index.
# Fast via: single playlist JSON, parallel per-video fetch, on-disk cache.
#
# Usage:
#   ./pawtag.sh --folder "yt_playlist_downloads" --playlist "https://www.youtube.com/playlist?list=XXXX" [options]
#
# Options:
#   --ff-profile "/path/to/firefox/profile"   (default: /home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default)
#   --ytdlp "./bin/yt-dlp"                    (default: ./bin/yt-dlp; auto-download if missing)
#   --album "YouTube: My Mix"                 (skip fetching playlist title)
#   --workers 8                               (parallel workers; default 8)
#   --no-cover                                (skip cover images)
#   --no-year                                 (skip upload year parsing)
#   --dry-run                                 (log only; no writes)

FOLDER=""
PLAYLIST=""
FF_PROFILE="${FF_PROFILE:-/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default}"
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
PawTagger FAST
--folder <dir>        Folder with files like '001 - Title.mp3'
--playlist <url>      YouTube playlist URL (index mapping)
--ff-profile <dir>    Firefox profile (default: $FF_PROFILE)
--ytdlp <path>        Path to yt-dlp (default: $YTDLP; auto-download if missing)
--album "<name>"      Force album name (skip fetching playlist title)
--workers <N>         Parallel fetch workers (default: 8)
--no-cover            Don't fetch/embed cover images (faster)
--no-year             Don't parse upload date for year (faster)
--dry-run             Log actions but don't modify files
EOF
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[ -n "$FOLDER" ]   || { echo "Missing --folder"; exit 1; }
[ -n "$PLAYLIST" ] || { echo "Missing --playlist"; exit 1; }
[ -d "$FOLDER" ]   || { echo "Folder not found: $FOLDER"; exit 1; }

# Ensure yt-dlp
if [ ! -x "$YTDLP" ]; then
  mkdir -p "$(dirname "$YTDLP")"
  echo "Getting latest yt-dlp..."
  if command -v curl >/dev/null 2>&1; then
    curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$YTDLP"
  else
    wget -O "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  fi
  chmod +x "$YTDLP"
fi

# Ensure mutagen
if ! python3 -c 'import mutagen' >/dev/null 2>&1; then
  echo "Installing Python 'mutagen'..."
  python3 -m pip install --user mutagen >/dev/null
fi

# Run tagger (fast)
python3 - "$FOLDER" "$PLAYLIST" "$YTDLP" "$FF_PROFILE" "$ALBUM_OVERRIDE" "$WORKERS" "$NO_COVER" "$NO_YEAR" "$DRY" <<'PY'
import sys, json, subprocess, tempfile, os, re, urllib.request, time, concurrent.futures
from pathlib import Path
from datetime import datetime

folder, playlist_url, ytdlp, ff_profile, album_override, workers, no_cover, no_year, dry = sys.argv[1:]
workers = int(workers); no_cover = int(no_cover); no_year = int(no_year); dry = int(dry)

def log(m): print(m, flush=True)
def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{p.stderr.strip()}")
    return p.stdout

CACHE = Path(".pawtag_cache.json")
cache = {}
if CACHE.exists():
    try:
        cache = json.loads(CACHE.read_text(encoding="utf-8"))
    except Exception:
        cache = {}

def save_cache():
    try:
        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:
        pass

def try_clients_get_json(url, clients=("android","tvhtml5","web")):
    last=None
    for c in clients:
        try:
            out = run([ytdlp, "--cookies-from-browser", f"firefox:{ff_profile}",
                       "--extractor-args", f"youtube:player_client={c}", "-j", url])
            return json.loads(out)
        except Exception as e:
            last=e
    raise last

def best_thumb(ts):
    if not ts: return None
    return max(ts, key=lambda t: t.get("height",0)).get("url")

def dl_thumb(u):
    if not u or no_cover: return None
    try:
        fd, path = tempfile.mkstemp(prefix="pawtag_", suffix=".jpg"); os.close(fd)
        urllib.request.urlretrieve(u, path)
        return path
    except Exception:
        return None

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

folder = Path(folder).expanduser().resolve()
log(f"🐾 PawTagger FAST — folder: {folder}")
log(f"🎶 Playlist: {playlist_url}")
log(f"🍪 Firefox:  {ff_profile}")
log(f"⚙️  yt-dlp:   {ytdlp}")
log(f"🚀 Workers:  {workers} | Cover: {'off' if no_cover else 'on'} | Year: {'off' if no_year else 'on'} | Dry: {bool(dry)}")

# 1) Single playlist JSON (title + entries)
log("📖 Fetching playlist JSON once (-J)…")
try:
    pl_json = json.loads(run([ytdlp, "--cookies-from-browser", f"firefox:{ff_profile}", "-J", playlist_url]))
except Exception as e:
    log(f"❌ Failed to load playlist JSON: {e}"); sys.exit(1)

entries = pl_json.get("entries") or []
idx_map = {}
for e in entries:
    try:
        idx = int(e.get("playlist_index") or 0)
        if idx > 0:
            idx_map[idx] = {"id": e.get("id"), "yt_title": e.get("title")}
    except Exception:
        continue

if not idx_map:
    log("🫥 No entries found in playlist JSON"); sys.exit(1)

album = album_override or f"YouTube: {pl_json.get('title') or 'Playlist'}"
log("="*72 + f"\n🎵 Now tagging album: {album}\n" + "="*72)

# 2) Gather files
rx = re.compile(r"^(\d{3})\s*-\s*.+\.(mp3|m4a)$", re.IGNORECASE)
files = sorted([p for p in folder.iterdir() if p.is_file() and rx.match(p.name)])
if not files:
    log("🫥 No matching files 'NNN - *.mp3/m4a'"); sys.exit(0)
log(f"🔍 Found {len(files)} file(s) to process")

# 3) Precompute which video IDs we need metadata for (and not cached)
need = []
file_infos = []  # (path, idx, ext, vid)
for f in files:
    m = rx.match(f.name)
    idx = int(m.group(1)); ext = m.group(2).lower()
    ent = idx_map.get(idx)
    if not ent or not ent.get("id"):
        log(f"[skip] No playlist entry for index {idx:03d} → {f.name}")
        continue
    vid = ent["id"]
    file_infos.append((f, idx, ext, vid, ent.get("yt_title")))
    if vid not in cache:
        need.append(vid)

log(f"🗂️  Cache: {len(cache)} known | Need fetch: {len(need)}")

# 4) Parallel fetch metadata for needed vids
def fetch_one(vid):
    url = f"https://www.youtube.com/watch?v={vid}"
    try:
        info = try_clients_get_json(url, clients=("android","tvhtml5","web"))
        data = {
            "title": info.get("title"),
            "uploader": info.get("uploader") or info.get("channel"),
            "upload_date": info.get("upload_date"),
            "thumbnail": None
        }
        thumbs = info.get("thumbnails") or []
        bt = None
        if thumbs:
            bt = max(thumbs, key=lambda t: t.get("height",0)).get("url")
        data["thumbnail"] = bt
        return vid, data, None
    except Exception as e:
        return vid, None, str(e)

if need:
    log(f"⚡ Fetching metadata in parallel with {workers} workers…")
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for vid, data, err in ex.map(fetch_one, need):
            if data:
                cache[vid] = data
            else:
                log(f"   ⚠️  {vid} metadata failed: {err}")
    save_cache()

# 5) Tag files
for f, idx, ext, vid, yt_title in file_infos:
    url = f"https://www.youtube.com/watch?v={vid}"
    data = cache.get(vid, {})
    title = data.get("title") or yt_title or f.name
    artist = data.get("uploader") or "YouTube"
    year = None
    if not no_year:
        up = data.get("upload_date")
        if isinstance(up, str) and len(up)==8:
            try: year = datetime.strptime(up, "%Y%m%d").year
            except Exception: year = None
    cover_url = None if no_cover else data.get("thumbnail")
    cover = None
    if cover_url:
        cover = dl_thumb(cover_url)

    log(f"[{idx:03d}] {f.name}")
    log(f"      title:  {title}")
    log(f"      artist: {artist}")
    log(f"      album:  {album}")
    log(f"      track#: {idx}")
    log(f"      year:   {year if year else 'unknown' if not no_year else '(skipped)'}")
    log(f"      id/url: {vid}  {url}")
    log(f"      cover:  {'yes' if cover else 'no'}")

    if dry:
        if cover and os.path.exists(cover): os.remove(cover)
        continue

    try:
        if ext == "mp3":
            tag_mp3(str(f), {"title":title,"artist":artist,"album":album,"track":idx,"year":year,"url":url,"id":vid}, cover)
        else:
            tag_m4a(str(f), {"title":title,"artist":artist,"album":album,"track":idx,"year":year,"url":url,"id":vid}, cover)
        log("   ✅ tagged")
    finally:
        if cover and os.path.exists(cover): os.remove(cover)

log("🎉 Done.")
PY
