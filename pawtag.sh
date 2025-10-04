#!/usr/bin/env bash
set -euo pipefail

# PawTagger (standalone)
# Tags existing MP3/M4A files by playlist index using YouTube metadata.
# Usage:
#   ./pawtag.sh --folder "yt_playlist_downloads" --playlist "https://www.youtube.com/playlist?list=XXXX" [--dry-run]
# Optional:
#   --ff-profile "/path/to/firefox/profile"  (default: Nicky's Snap profile)
#   --ytdlp "./bin/yt-dlp"                   (default: ./bin/yt-dlp; auto-download if missing)

FOLDER=""
PLAYLIST=""
FF_PROFILE="${FF_PROFILE:-/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default}"
YTDLP="${YTDLP:-./bin/yt-dlp}"
DRY=0

# --- parse args ---
while [ $# -gt 0 ]; do
  case "$1" in
    --folder)    FOLDER="${2:-}"; shift 2;;
    --playlist)  PLAYLIST="${2:-}"; shift 2;;
    --ff-profile)FF_PROFILE="${2:-}"; shift 2;;
    --ytdlp)     YTDLP="${2:-}"; shift 2;;
    --dry-run)   DRY=1; shift;;
    -h|--help)
      echo "PawTagger (standalone)"
      echo "  --folder <dir>      Folder with files like '001 - Title.mp3'"
      echo "  --playlist <url>    YouTube playlist URL"
      echo "  --ff-profile <dir>  Firefox profile path (default: $FF_PROFILE)"
      echo "  --ytdlp <path>      Path to yt-dlp (default: $YTDLP; auto-download if missing)"
      echo "  --dry-run           Show actions, don't write tags"
      exit 0;;
    *)
      echo "Unknown arg: $1"; exit 1;;
  esac
done

[ -n "$FOLDER" ] || { echo "Missing --folder"; exit 1; }
[ -n "$PLAYLIST" ] || { echo "Missing --playlist"; exit 1; }
[ -d "$FOLDER" ] || { echo "Folder not found: $FOLDER"; exit 1; }

# --- ensure yt-dlp available (self-contained local copy by default) ---
if [ ! -x "$YTDLP" ]; then
  mkdir -p "$(dirname "$YTDLP")"
  echo "Getting latest yt-dlp to $YTDLP…"
  if command -v curl >/dev/null 2>&1; then
    curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$YTDLP"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  else
    echo "Need curl or wget to fetch yt-dlp"; exit 1
  fi
  chmod +x "$YTDLP"
fi

# --- ensure mutagen present for tagging ---
if ! python3 -c 'import mutagen' >/dev/null 2>&1; then
  echo "Installing Python 'mutagen' for tagging…"
  python3 -m pip install --user mutagen >/dev/null
fi

# --- run the tagger (embedded Python) ---
python3 - "$FOLDER" "$PLAYLIST" "$YTDLP" "$FF_PROFILE" "$DRY" <<'PY'
import sys, json, subprocess, tempfile, os, re, urllib.request
from pathlib import Path
from datetime import datetime

folder, playlist_url, ytdlp, ff_profile, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])

def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return p.stdout

def try_clients(url, clients=("android","tvhtml5","web")):
    last=None
    for c in clients:
        try:
            out = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}",
                       "--extractor-args",f"youtube:player_client={c}","-j",url])
            return json.loads(out)
        except Exception as e:
            last=e
    raise last

def best_thumb(ts):
    if not ts: return None
    return max(ts, key=lambda t: t.get("height",0)).get("url")

def dl_thumb(u):
    if not u: return None
    try:
        fd, path = tempfile.mkstemp(prefix="pawtag_", suffix=".jpg"); os.close(fd)
        urllib.request.urlretrieve(u, path)
        return path
    except Exception:
        return None

def tag_mp3(path, meta, cover):
    from mutagen.id3 import ID3, APIC, TIT2, TPE1, TALB, TRCK, TDRC, COMM
    try:
        tags = ID3(path)
    except Exception:
        tags = ID3()
    if meta.get("title"):  tags.add(TIT2(encoding=3,text=meta["title"]))
    if meta.get("artist"): tags.add(TPE1(encoding=3,text=meta["artist"]))
    if meta.get("album"):  tags.add(TALB(encoding=3,text=meta["album"]))
    if meta.get("track"):  tags.add(TRCK(encoding=3,text=str(meta["track"])))
    if meta.get("year"):   tags.add(TDRC(encoding=3,text=str(meta["year"])))
    c = (meta.get("url") or "") + (f" (id={meta.get('id')})" if meta.get("id") else "")
    if c.strip():          tags.add(COMM(encoding=3,desc="comment",text=c.strip()))
    if cover:
        with open(cover,"rb") as f: data=f.read()
        tags.add(APIC(encoding=3,mime="image/jpeg",type=3,desc="Cover",data=data))
    tags.save(path)

def tag_m4a(path, meta, cover):
    from mutagen.mp4 import MP4, MP4Cover
    a=MP4(path)
    if meta.get("title"):  a["\xa9nam"]=meta["title"]
    if meta.get("artist"): a["\xa9ART"]=meta["artist"]
    if meta.get("album"):  a["\xa9alb"]=meta["album"]
    if meta.get("track"):  a["trkn"]=[(int(meta["track"]),0)]
    if meta.get("year"):   a["\xa9day"]=str(meta["year"])
    if meta.get("url"):    a["----:com.apple.iTunes:url"]=[meta["url"].encode()]
    if meta.get("id"):     a["----:com.apple.iTunes:youtube_id"]=[meta["id"].encode()]
    if cover:
        with open(cover,"rb") as f: data=f.read()
        a["covr"]=[MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG)]
    a.save()

folder = Path(folder).expanduser().resolve()
print(f"PawTagger: scanning {folder}")

# Build index->id map from playlist (flat print is fast)
flat = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}","--flat-playlist","--print","%(playlist_index)s\t%(id)s\t%(title)s",playlist_url])
idx_map={}
for line in flat.splitlines():
    parts=line.strip().split("\t",2)
    if len(parts)>=2 and parts[0].isdigit():
        idx_map[int(parts[0])]={"id":parts[1], "yt_title": parts[2] if len(parts)>2 else None}

# Get playlist title for album field
album="YouTube Playlist"
try:
    pl = run([ytdlp,"--cookies-from-browser",f"firefox:{ff_profile}","-j",playlist_url])
    album = f"YouTube: {json.loads(pl).get('title') or 'Playlist'}"
except Exception:
    pass

rx = re.compile(r"^(\d{3})\s*-\s*.+\.(mp3|m4a)$", re.IGNORECASE)
files = sorted([p for p in folder.iterdir() if p.is_file() and rx.match(p.name)])
if not files:
    print("PawTagger: no 'NNN - *.mp3/m4a' files found."); sys.exit(0)

for f in files:
    m = rx.match(f.name); idx=int(m.group(1)); ext=m.group(2).lower()
    ent = idx_map.get(idx)
    if not ent:
        print(f"[skip] no playlist entry for index {idx:03d} → {f.name}")
        continue

    vid = ent["id"]; vurl=f"https://www.youtube.com/watch?v={vid}"
    print(f"[{idx:03d}] tagging {f.name}  ←  {vid}")

    try:
        info = try_clients(vurl, clients=("android","tvhtml5","web"))
    except Exception as e:
        print(f"  ! metadata fetch failed: {e}")
        continue

    title = info.get("title") or ent.get("yt_title") or f.name
    artist = info.get("uploader") or info.get("channel") or "YouTube"
    url = info.get("webpage_url") or vurl
    year=None
    up=info.get("upload_date")
    if isinstance(up,str) and len(up)==8:
        try:
            year=datetime.strptime(up,"%Y%m%d").year
        except Exception:
            year=None

    cover_url = best_thumb(info.get("thumbnails") or [])
    cover = dl_thumb(cover_url)

    meta={"title":title,"artist":artist,"album":album,"track":idx,"year":year,"url":url,"id":vid}

    try:
        if dry:
            print(f"  (dry) title='{title}' artist='{artist}' album='{album}' track={idx} year={year} cover={'yes' if cover else 'no'}")
        else:
            if ext=="mp3": tag_mp3(str(f),meta,cover)
            else:          tag_m4a(str(f),meta,cover)
            print("  ✓ tagged")
    finally:
        if cover and os.path.exists(cover): os.remove(cover)
PY

echo "✅ PawTagger finished."
