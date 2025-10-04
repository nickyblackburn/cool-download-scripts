#!/usr/bin/env bash
set -euo pipefail

# PawTagger FAST (bulk) — tags existing MP3/M4A by playlist index.
# - No media downloads, no renaming
# - Single playlist fetch (with fallbacks), then BULK metadata fetch
# - Caches results in .pawtag_cache.json
#
# Usage:
#   ./pawtag.sh --folder "yt_downloaded" \
#               --playlist "https://www.youtube.com/playlist?list=XXXX" \
#               [--album "YouTube: My Mix"] [--no-cover] [--no-year] [--dry-run] \
#               [--ff-profile "/path/to/firefox/profile"] [--ytdlp "./bin/yt-dlp"]

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
say(){ printf "%b\n" "$*${RESET}"; }

FOLDER=""
PLAYLIST=""
FF_PROFILE_DEFAULT="$(printf "%s" "$HOME/snap/firefox/common/.mozilla/firefox"/*default* 2>/dev/null || true)"
FF_PROFILE="${FF_PROFILE:-${FF_PROFILE_DEFAULT:-$HOME/.mozilla/firefox}}"
YTDLP="${YTDLP:-./bin/yt-dlp}"
ALBUM_OVERRIDE=""
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
    --no-cover)   NO_COVER=1; shift;;
    --no-year)    NO_YEAR=1; shift;;
    --dry-run)    DRY=1; shift;;
    -h|--help)
      cat <<EOF
${BOLD}PawTagger FAST (bulk)${RESET}
Tags existing MP3/M4A files by playlist index using BULK metadata fetch.

Required:
  --folder <dir>        Folder with files like '001 - Title.mp3'
  --playlist <url>      YouTube playlist URL (maps 001->index 1, etc.)

Options:
  --album "<name>"      Force album name (skip playlist title fetch)
  --no-cover            Skip cover images (faster)
  --no-year             Skip upload year tagging (faster)
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
say "⚙️  Cover: $([ $NO_COVER -eq 1 ] && echo off || echo on) | Year: $([ $NO_YEAR -eq 1 ] && echo off || echo on) | Dry: $([ $DRY -eq 1 ] && echo True || echo False)"

# Ensure yt-dlp
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

# Ensure mutagen
if ! python3 -c 'import mutagen' >/dev/null 2>&1; then
  say "📦 Installing Python 'mutagen'…"
  python3 -m pip install --user mutagen >/dev/null
fi

# Run the tagger (bulk)
python3 - "$FOLDER" "$PLAYLIST" "$YTDLP" "$FF_PROFILE" "$ALBUM_OVERRIDE" "$NO_COVER" "$NO_YEAR" "$DRY" <<'PY'
import sys, json, subprocess, tempfile, os, re, urllib.request
from pathlib import Path
from datetime import datetime

folder, playlist_url, ytdlp, ff_profile, album_override, no_cover, no_year, dry = sys.argv[1:]
no_cover = int(no_cover); no_year = int(no_year); dry = int(dry)

def log(m): print(m, flush=True)
def run(cmd, timeout=None):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or '').strip() or "command failed")
    return p.stdout

# Cache
CACHE = Path(".pawtag_cache.json")
cache = {}
if CACHE.exists():
    try: cache = json.loads(CACHE.read_text(encoding="utf-8"))
    except Exception: cache = {}
def save_cache():
    try: CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception: pass

folder = Path(folder).expanduser().resolve()

# Files to tag
rx = re.compile(r"^(\d{3})\s*-\s*(.+)\.(mp3|m4a)$", re.IGNORECASE)
files = sorted([p for p in folder.iterdir() if p.is_file() and rx.match(p.name)])
if not files:
    log("🫥 No files matching 'NNN - *.mp3/m4a'."); sys.exit(0)
log(f"🔍 Found {len(files)} file(s) to process.")

# --- Get playlist mapping with fallbacks ---
log("📖 Fetching playlist JSON once (-J)…")
def ytdlp_json_with_timeout(args, timeout=25):
    out = run(args, timeout=timeout)
    return json.loads(out)

pl_json = None
errs = []

# A) web + cookies
try:
    pl_json = ytdlp_json_with_timeout([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                                       "--force-ipv4","--extractor-args","youtube:player_client=web",
                                       "-J",playlist_url], timeout=25)
except Exception as e: errs.append(f"A(web+cookies): {e}")

# B) android + cookies
if pl_json is None:
    try:
        pl_json = ytdlp_json_with_timeout([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                                           "--force-ipv4","--extractor-args","youtube:player_client=android",
                                           "-J",playlist_url], timeout=25)
    except Exception as e: errs.append(f"B(android+cookies): {e}")

# C) web no-cookies
if pl_json is None:
    try:
        pl_json = ytdlp_json_with_timeout([ytdlp,"--force-ipv4","--extractor-args","youtube:player_client=web",
                                           "-J",playlist_url], timeout=20)
    except Exception as e: errs.append(f"C(web no-cookies): {e}")

idx_map = {}
if pl_json is None:
    log("⚠️  -J failed; falling back to flat index map…")
    try:
        flat = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}","--force-ipv4",
                    "--flat-playlist","--print","%(playlist_index)s\t%(id)s\t%(title)s", playlist_url], timeout=25)
    except Exception as e:
        log("❌ Could not build index map from flat playlist.")
        for er in errs: log("   " + er)
        sys.exit(1)
    for line in flat.splitlines():
        parts = line.strip().split("\t", 3)
        if len(parts) >= 2 and parts[0].isdigit():
            idx_map[int(parts[0])] = {"id": parts[1], "yt_title": parts[2] if len(parts)>2 else None}
    album = album_override or "YouTube Playlist"
else:
    entries = pl_json.get("entries") or []
    for e in entries:
        try:
            idx = int(e.get("playlist_index") or 0)
            if idx > 0:
                idx_map[idx] = {"id": e.get("id"), "yt_title": e.get("title")}
        except Exception: pass
    if not idx_map:
        log("🫥 No entries found in playlist JSON.")
        for er in errs: log("   " + er)
        sys.exit(1)
    album = album_override or f"YouTube: {pl_json.get('title') or 'Playlist'}"

print("="*72 + f"\n🎵 Now tagging album: {album}\n" + "="*72)

# --- Build list + what's needed ---
file_items = []  # (path, idx, ext, body)
for f in files:
    m = rx.match(f.name); idx = int(m.group(1)); body = m.group(2); ext = m.group(3).lower()
    file_items.append((f, idx, ext, body))
file_items.sort(key=lambda x: x[1])

needed = []
for _, idx, _, _ in file_items:
    ent = idx_map.get(idx)
    if not ent or not ent.get("id"): continue
    vid = ent["id"]
    if vid not in cache:
        needed.append(vid)

log(f"🗂️  Cache: {len(cache)} entries | Need fetch: {len(needed)}")

# --- BULK METADATA FETCH (fast) ---
def bulk_fetch(urls, client, use_cookies=True, timeout=60):
    if not urls: return {}
    fd, listfile = tempfile.mkstemp(prefix="pawtag_urls_", suffix=".txt")
    os.close(fd)
    Path(listfile).write_text("\n".join(urls), encoding="utf-8")
    cmd = [ytdlp,
           "--force-ipv4",
           "--extractor-args", f"youtube:player_client={client}",
           "--ignore-config",
           "--no-warnings",
           "--no-playlist",
           "--no-download",
           "--print", "%(id)s\t%(title)s\t%(uploader)s\t%(upload_date)s\t%(thumbnail)s",
           "--batch-file", listfile]
    if use_cookies:
        cmd[1:1] = ["--cookies-from-browser", f"firefox:{ff_profile}"]
    out = ""
    try:
        out = run(cmd, timeout=timeout)
    finally:
        try: os.remove(listfile)
        except Exception: pass
    result = {}
    for line in out.splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 5:
            vid, title, uploader, udate, thumb = parts[:5]
            result[vid] = {
                "title": title or None,
                "uploader": uploader or None,
                "upload_date": udate or None,
                "thumbnail": thumb or None
            }
    return result

remaining = set(needed)
attempts = [
    ("android", True),
    ("tvhtml5", True),
    ("web", True),
    ("android", False),
    ("web", False),
]
for client, use_cookies in attempts:
    if not remaining:
        break
    urls = [f"https://www.youtube.com/watch?v={vid}" for vid in remaining]
    try:
        chunk = bulk_fetch(urls, client=client, use_cookies=use_cookies, timeout=60)
        for vid, data in chunk.items():
            cache[vid] = data
        remaining -= set(chunk.keys())
        if chunk:
            print(f"   ✓ bulk {client} ({'cookies' if use_cookies else 'no-cookies'}): {len(chunk)}")
    except Exception as e:
        print(f"   ⚠️ bulk {client} ({'cookies' if use_cookies else 'no-cookies'}) failed: {e}")

if remaining:
    print(f"   ⚠️ {len(remaining)} item(s) still missing metadata; will tag using filename fallbacks.")
# persist cache
try:
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
except Exception:
    pass

def dl_thumb(u):
    if not u or no_cover: return None
    try:
        fd, path = tempfile.mkstemp(prefix="pawtag_", suffix=".jpg"); os.close(fd)
        urllib.request.urlretrieve(u, path)
        return path
    except Exception: return None

# Taggers
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

# Filename fallback parser
def parse_artist_title(name_body):
    parts = [s.strip() for s in name_body.split(" - ", 1)]
    if len(parts) == 2: return parts[0], parts[1]
    return None, name_body

# Tag loop
for f in file_items:
    path, idx, ext, body = f
    ent = idx_map.get(idx) or {}
    vid = ent.get("id")
    url = f"https://www.youtube.com/watch?v={vid}" if vid else ""
    data = cache.get(vid, {}) if vid else {}

    title  = data.get("title") or ent.get("yt_title") or None
    artist = data.get("uploader") or None
    if title is None or artist is None:
        a2, t2 = parse_artist_title(body)
        title  = title  or t2
        artist = artist or (a2 or "Unknown")

    year = None
    if not no_year:
        up = data.get("upload_date")
        if isinstance(up, str) and len(up)==8:
            try: year = datetime.strptime(up, "%Y%m%d").year
            except Exception: year = None

    cover_path = dl_thumb(data.get("thumbnail"))

    print(f"[{idx:03d}] {path.name}")
    print(f"      title:  {title}")
    print(f"      artist:{' ' if artist else ''}{artist if artist else 'Unknown'}")
    print(f"      album:  {album}")
    print(f"      track#: {idx}")
    print(f"      year:   {year if year is not None else ('(skipped)' if no_year else 'unknown')}")
    print(f"      id/url: {vid if vid else '(none)'}  {url if url else ''}")
    print(f"      cover:  {'yes → ' + Path(cover_path).name if cover_path else ('(skipped)' if no_cover else 'no')}")

    if dry:
        if cover_path and os.path.exists(cover_path): os.remove(cover_path)
        continue

    meta = {"title":title,"artist":artist,"album":album,"track":idx,"year":year,"url":url,"id":vid}
    try:
        if ext=="mp3": tag_mp3(str(path), meta, cover_path)
        else:          tag_m4a(str(path), meta, cover_path)
        print("   ✅ tagged")
    finally:
        if cover_path and os.path.exists(cover_path): os.remove(cover_path)

print("🎉 Done.")
PY

say "${GREEN}✅ PawTagger finished.${RESET}"
