#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

version=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' install.xml | head -n 1)
archive="dist/ShazamCapture-$version.zip"

test -f "$archive"
xmllint --noout install.xml repo.xml

repo_version=$(sed -n 's:.*<plugin name="ShazamCapture" version="\([^"]*\)".*:\1:p' repo.xml)
repo_sha=$(sed -n 's:.*<sha>\([^<]*\)</sha>.*:\1:p' repo.xml)
archive_sha=$(shasum -a 1 "$archive" | awk '{print $1}')

test "$repo_version" = "$version"
test "$repo_sha" = "$archive_sha"

zipinfo -1 "$archive" | grep -qx 'install.xml'
if zipinfo -1 "$archive" | grep -Eq '(^|/)venv/|(^|/)var/|(^|/)\.git'; then
	printf '%s\n' 'Release contains excluded development or runtime state' >&2
	exit 1
fi

printf 'Verified ShazamCapture %s (%s)\n' "$version" "$archive_sha"
