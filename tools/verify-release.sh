#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

version=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' install.xml | head -n 1)
archive="dist/ShazamCapture-$version.zip"

test -f "$archive"
xmllint --noout install.xml repo.xml

rg -q '^cat > custom-init\.sh <<' docs/CUSTOM-INIT-PASTE.md
rg -q '^SHAZAMCAPTURE_INIT_EOF$' docs/CUSTOM-INIT-PASTE.md
awk '
	/^cat > custom-init\.sh <</ { copying = 1; next }
	copying && /^SHAZAMCAPTURE_INIT_EOF$/ { exit }
	copying { print }
' docs/CUSTOM-INIT-PASTE.md | cmp - docker/custom-init.sh

repo_version=$(sed -n 's:.*<plugin name="ShazamCapture" version="\([^"]*\)".*:\1:p' repo.xml)
repo_sha=$(sed -n 's:.*<sha>\([^<]*\)</sha>.*:\1:p' repo.xml)
archive_sha=$(shasum -a 1 "$archive" | awk '{print $1}')

test "$repo_version" = "$version"
test "$repo_sha" = "$archive_sha"

python3 - "$archive" "$version" <<'PY'
import datetime
import sys
import zipfile

parts = [int(part) for part in sys.argv[2].split('.')]
base = int(datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc).timestamp())
stamp = base + parts[0] * 1_000_000_000 + parts[1] * 1_000_000 + parts[2] * 1000
expected = datetime.datetime.fromtimestamp(stamp).timetuple()[:6]
with zipfile.ZipFile(sys.argv[1]) as archive:
    actual = archive.getinfo('strings.txt').date_time
if actual != expected:
    raise SystemExit(f'Incorrect strings.txt release timestamp: {actual} != {expected}')
PY

zipinfo -1 "$archive" | grep -qx 'install.xml'
for page in basic player; do
	zipinfo -1 "$archive" | grep -qx "HTML/EN/plugins/ShazamCapture/settings/$page-v$version.html"
	unzip -p "$archive" "HTML/EN/plugins/ShazamCapture/settings/$page-v$version.html" |
		cmp - "HTML/EN/plugins/ShazamCapture/settings/$page.html"
done
if zipinfo -1 "$archive" | grep -Eq '(^|/)venv/|(^|/)var/|(^|/)\.git'; then
	printf '%s\n' 'Release contains excluded development or runtime state' >&2
	exit 1
fi

printf 'Verified ShazamCapture %s (%s)\n' "$version" "$archive_sha"
