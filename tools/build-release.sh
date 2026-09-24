#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

version=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' install.xml | head -n 1)
if [ -z "$version" ]; then
	printf '%s\n' 'Unable to read the plugin version from install.xml' >&2
	exit 1
fi

archive="ShazamCapture-$version.zip"
output_dir="$project_root/dist"
archive_path="$output_dir/$archive"
stage=$(mktemp -d "${TMPDIR:-/tmp}/shazamcapture-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

mkdir -p "$output_dir"
rm -f "$archive_path"

cp install.xml strings.txt README.md "$stage/"
cp -R HTML lib python "$stage/"
for page in basic player; do
	cp "$stage/HTML/EN/plugins/ShazamCapture/settings/$page.html" \
		"$stage/HTML/EN/plugins/ShazamCapture/settings/$page-v$version.html"
done
rm -rf "$stage/python/venv"
find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$stage" \( -name '*.pyc' -o -name '.DS_Store' \) -type f -delete
find "$stage" -exec touch -t 200001010000 {} +

# LMS validates its parsed string cache using source-file mtimes. A fixed
# archive timestamp lets old translations survive a plugin upgrade, so give
# strings.txt a reproducible timestamp that changes with the release version.
python3 - "$stage/strings.txt" "$version" <<'PY'
import datetime
import os
import sys

parts = [int(part) for part in sys.argv[2].split('.')]
if len(parts) != 3 or any(part < 0 or part >= 1000 for part in parts):
    raise SystemExit('Expected a three-part numeric plugin version')
base = int(datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc).timestamp())
stamp = base + parts[0] * 1_000_000_000 + parts[1] * 1_000_000 + parts[2] * 1000
os.utime(sys.argv[1], (stamp, stamp))
PY

(
	cd "$stage"
	find . -mindepth 1 -print | LC_ALL=C sort | zip -X -q "$archive_path" -@
)

sha=$(shasum -a 1 "$archive_path" | awk '{print $1}')
repo_url="https://github.com/DexiTheOne/LMS-Music-Recognition/releases/download/v$version/$archive"

sed \
	-e "s|@VERSION@|$version|g" \
	-e "s|@SHA1@|$sha|g" \
	-e "s|@ARCHIVE_URL@|$repo_url|g" \
	tools/repo.xml.in > repo.xml

printf 'Built %s\nSHA-1: %s\nRepository: %s\n' "$archive_path" "$sha" "$project_root/repo.xml"
