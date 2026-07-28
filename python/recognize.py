#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from urllib.parse import urlsplit, urlunsplit

PLUGIN_ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))

def emit(obj, code=0):
    print(json.dumps(obj, separators=(",", ":")))
    raise SystemExit(code)

def inside(path):
    path = os.path.realpath(path)
    return path == PLUGIN_ROOT or path.startswith(PLUGIN_ROOT + os.sep)

async def recognize(wav, sample_seconds):
    from shazamio import Shazam
    return await Shazam(segment_duration_seconds=sample_seconds).recognize(wav)

def debug_wav_path(title):
    safe = "".join(c if c.isalnum() or c in (" ", "-", "_") else "-" for c in (title or "NoResult"))
    safe = re.sub(r"[\s_-]+", "-", safe).strip("-") or "NoResult"
    safe = safe[:100].rstrip("-_") or "NoResult"
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    dumps = os.path.join(PLUGIN_ROOT, "var", "dumps")
    os.makedirs(dumps, exist_ok=True)
    candidate = os.path.join(dumps, f"{safe}-{stamp}.wav")
    number = 2
    while os.path.exists(candidate):
        candidate = os.path.join(dumps, f"{safe}-{stamp}-{number}.wav")
        number += 1
    return candidate

def first_uri(items, prefix=None):
    for item in items or []:
        for action in item.get("actions") or []:
            uri = action.get("uri")
            if uri and (not prefix or uri.startswith(prefix)):
                return uri

def metadata_value(track, wanted):
    for section in track.get("sections") or []:
        for item in section.get("metadata") or []:
            if str(item.get("title") or "").strip().lower() in wanted:
                return item.get("text")

def clean_url(url):
    if not url:
        return url
    parts = urlsplit(url)
    scheme = parts.scheme
    netloc = parts.netloc
    if (parts.hostname or "").lower() == "music.apple.com":
        scheme = "https"
        netloc = "music.apple.com"
    return urlunsplit((scheme, netloc, parts.path, "", ""))

def spotify_url(items):
    fallback = None
    for item in items or []:
        for action in item.get("actions") or []:
            uri = action.get("uri")
            if not uri:
                continue
            if (urlsplit(uri).hostname or "").lower() == "open.spotify.com":
                return clean_spotify_url(uri)
            if uri.lower().startswith(("spotify:track:", "spotify://track/")):
                fallback = fallback or uri
    return clean_spotify_url(fallback)

def clean_spotify_url(url):
    if not url:
        return None
    if url.lower().startswith("spotify:track:"):
        track_id = url.split(":", 2)[2].split("?", 1)[0].split("#", 1)[0]
        return f"https://open.spotify.com/track/{track_id}" if track_id else None
    if url.lower().startswith("spotify://track/"):
        track_id = url[len("spotify://track/"):].split("?", 1)[0].split("#", 1)[0]
        return f"https://open.spotify.com/track/{track_id}" if track_id else None
    parts = urlsplit(url)
    if (parts.hostname or "").lower() != "open.spotify.com":
        return None
    return urlunsplit(("https", "open.spotify.com", parts.path, "", ""))

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--timeout", type=int, default=20)
    p.add_argument("--sample-seconds", type=int, default=10, choices=range(5, 31))
    p.add_argument("--save-debug-wav", action="store_true")
    a = p.parse_args()
    if not inside(a.input) or not os.path.isfile(a.input):
        emit({"ok":False,"stage":"input","error":"Input must be a file inside the plugin directory"}, 2)
    fd, wav = tempfile.mkstemp(prefix="shazam_", suffix=".wav", dir=os.path.join(PLUGIN_ROOT,"var","tmp"))
    os.close(fd)
    submitted = False
    debug_title = None
    try:
        ffmpeg = os.environ.get("SHAZAMCAPTURE_FFMPEG")
        if not ffmpeg:
            try:
                import imageio_ffmpeg
                ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
            except Exception:
                ffmpeg = "ffmpeg"
        input_args = ["-f","s16le","-ar","16000","-ac","1"] if a.input.endswith(".s16le") else []
        cmd = [ffmpeg,"-hide_banner","-loglevel","error",*input_args,"-i",a.input,
               "-t",str(a.sample_seconds),
               "-vn","-ac","1","-ar","16000","-c:a","pcm_s16le","-f","wav","-y",wav]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=a.timeout, check=False)
        except FileNotFoundError:
            emit({"ok":False,"stage":"ffmpeg","error":"FFmpeg executable was not found"}, 3)
        except subprocess.TimeoutExpired:
            emit({"ok":False,"stage":"ffmpeg","error":"FFmpeg timed out"}, 4)
        if proc.returncode:
            print(proc.stderr.decode("utf-8","replace")[-2000:], file=sys.stderr)
            emit({"ok":False,"stage":"ffmpeg","error":"Unable to decode captured stream"}, 5)
        try:
            submitted = True
            result = asyncio.run(asyncio.wait_for(
                recognize(wav, a.sample_seconds), timeout=a.timeout
            ))
        except ImportError:
            emit({"ok":False,"stage":"dependency","error":"shazamio is not installed in the plugin-local environment"}, 6)
        except asyncio.TimeoutError:
            emit({"ok":False,"stage":"shazam","error":"Recognition timed out"}, 7)
        except Exception as exc:
            print(repr(exc), file=sys.stderr)
            emit({"ok":False,"stage":"shazam","error":"Recognition request failed"}, 8)
        track = ((result or {}).get("track") or {})
        matches = (result or {}).get("matches") or []
        if not track:
            emit({"ok":True,"matched":False,"matches":len(matches)})
        debug_title = track.get("title")
        hub = track.get("hub") or {}
        images = track.get("images") or {}
        apple_music_url = first_uri(hub.get("options"), "https://music.apple.com/")
        if not apple_music_url:
            apple_music_url = first_uri(hub.get("options"))
        apple_music_url = clean_url(apple_music_url)
        spotify = spotify_url(hub.get("providers"))
        emit({"ok":True,"matched":True,"track":{
            "title":track.get("title"),"artist":track.get("subtitle"),
            "album":metadata_value(track, {"album"}),
            "apple_music_url":apple_music_url,
            "spotify_url":spotify,
            "artwork_url":images.get("coverart") or images.get("coverarthq"),
            "shazam_url":track.get("url"),
            "shazam_key":track.get("key")},"matches":len(matches)})
    finally:
        if a.save_debug_wav and submitted:
            try:
                os.replace(wav, debug_wav_path(debug_title))
            except OSError as exc:
                print(f"Unable to retain debug WAV: {exc}", file=sys.stderr)
        try:
            os.unlink(wav)
        except OSError:
            pass

if __name__ == "__main__":
    main()
