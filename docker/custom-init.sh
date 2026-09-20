#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install --no-install-recommends -qy \
	python3 python3-venv ca-certificates fontconfig fonts-dejavu-core

plugin_root=/config/cache/InstalledPlugins/Plugins/ShazamCapture
requirements="$plugin_root/python/requirements.txt"
venv="$plugin_root/python/venv"

if [ ! -f "$requirements" ]; then
	printf '%s\n' 'Shazam Capture is not installed yet; dependency setup will run on the next container start.'
	exit 0
fi

if [ ! -x "$venv/bin/python" ]; then
	python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --disable-pip-version-check --upgrade -r "$requirements"
"$venv/bin/python" -m pip check
