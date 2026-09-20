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
rm -rf "$stage/python/venv"
find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$stage" \( -name '*.pyc' -o -name '.DS_Store' \) -type f -delete
find "$stage" -exec touch -t 200001010000 {} +

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
