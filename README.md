# 🎶 PawDownloaders  
**by Nicky Blackburn 🐾**  
Simple, reliable shell scripts for downloading and tagging music from **YouTube** and **SoundCloud** — built for Paw OS.  

---

## 🐾 Overview

These scripts let you easily fetch, tag, and organize your favorite tracks — all locally, no subscription required.  
They use [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) + `ffmpeg` under the hood, and include:
- Smart retry + skip logic (no re-downloads)
- Auto-metadata tagging
- Cookie support for private/age-gated content
- Folder + archive management
- Pretty log output and auto-update support

---

## 📦 Requirements
You’ll need:
- `bash`
- `ffmpeg` (for MP3 conversion)
- `curl` *or* `wget`
- (optional) `python3` (for URL decoding & random sleep)
- (optional) Firefox cookies (for private playlists)

Install with:
```bash
sudo apt install ffmpeg curl python3
```

---

## 🎥 YouTube Downloader

**File:** `youtubedownloader.sh`  
Downloads any **YouTube playlist or video** as MP3 with metadata.

### Example Usage

```bash
# Download a YouTube playlist
./youtubedownloader.sh "https://www.youtube.com/playlist?list=PLV33lbGV28lCVpVHrdJMuC2_93MflkbRg"

# Download a single video
./youtubedownloader.sh "https://www.youtube.com/watch?v=abcd1234"
```

### Features
✅ Bulk playlist or single-video download  
✅ Auto-fetches yt-dlp binary  
✅ Uses Firefox cookies for login-required videos  
✅ Creates `yt_downloaded/` folder  
✅ Skips files already in `archive.txt`  
✅ Supports metadata embedding and album tagging  

### Cookie Example
```bash
COOKIES_FROM_FIREFOX=1 FIREFOX_PROFILE="/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default"   ./youtubedownloader.sh "https://www.youtube.com/playlist?list=XXXX"
```

---

## ☁️ SoundCloud Downloader

**File:** `soundcloud_downloader.sh`  
Fetches SoundCloud **tracks**, **sets/playlists**, or **likes** lists as MP3 with thumbnails and tags.

### Example Usage
```bash
# Single track
./soundcloud_downloader.sh "https://soundcloud.com/artist/track-name"

# Playlist / Set
./soundcloud_downloader.sh "https://soundcloud.com/artist/sets/my-favorites"

# Your likes (may need cookies)
COOKIES_FROM_FIREFOX=1 FIREFOX_PROFILE="/home/nicky/snap/firefox/common/.mozilla/firefox/gevgkxp9.default"   ./soundcloud_downloader.sh "https://soundcloud.com/you/likes"
```

### Features
✅ Works on public or private playlists  
✅ Skips duplicates with `archive.txt`  
✅ Auto-tags title, artist, and album info  
✅ MP3 conversion with high quality (`--audio-quality 0`)  
✅ Optional Firefox cookies for logged-in content  
✅ Friendly log output with random sleep to avoid rate-limits  

---

## 🗂️ Output Structure
```
yt_downloaded/
├── 001 - Artist - Song Name.mp3
├── 002 - Artist - Song Name.mp3
└── archive.txt

sc_downloads/
├── 001 - Artist - Track Title.mp3
├── 002 - Artist - Track Title.mp3
└── archive.txt
``` 

---

## 🧸 Credits
**Scripts developed and debugged by:**  
🐾 **Nicky Blackburn** — Lead Developer of Paw OS  
Assisted by the script kitty 

---

## 🐕‍🦺 License
MIT License — Free to modify, remix, and share.  
Please respect content creators’ rights and use ethically.
