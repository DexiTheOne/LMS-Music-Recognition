#!/usr/bin/env python3
import argparse
import os

import imageio_ffmpeg

from recognize import PLUGIN_ROOT, inside, station_artwork

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--station", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=int, default=8)
    args = parser.parse_args()
    if not inside(args.output):
        raise SystemExit(2)
    os.makedirs(os.path.join(PLUGIN_ROOT, "var", "tmp"), exist_ok=True)
    ok = station_artwork(
        args.url,
        args.station,
        args.output,
        imageio_ffmpeg.get_ffmpeg_exe(),
        args.timeout,
    )
    raise SystemExit(0 if ok else 1)

if __name__ == "__main__":
    main()
