# Paste-ready Docker init script

Run this block from inside `/config`. It replaces `custom-init.sh` with the
current script and makes it executable. Restart the container before upgrading
Shazam Capture from an installation that still has `python/venv` inside the
plugin directory.

```sh
cat > custom-init.sh <<'SHAZAMCAPTURE_INIT_EOF'
#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install --no-install-recommends -qy \
	python3 python3-venv ca-certificates fontconfig fonts-dejavu-core

plugin_root=/config/cache/InstalledPlugins/Plugins/ShazamCapture
requirements="$plugin_root/python/requirements.txt"
venv=/config/cache/ShazamCapture-venv
legacy_venv="$plugin_root/python/venv"

if [ ! -f "$requirements" ]; then
	printf '%s\n' 'Shazam Capture is not installed yet; dependency setup will run on the next container start.'
	exit 0
fi

if [ ! -x "$venv/bin/python" ]; then
	python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --disable-pip-version-check --upgrade -r "$requirements"
"$venv/bin/python" -m pip check

# The old location blocks LMS from replacing the plugin during upgrades.
# Remove only this generated environment after its replacement is ready.
if [ -L "$legacy_venv" ]; then
	printf '%s\n' "Refusing to remove a symbolic-link legacy environment: $legacy_venv" >&2
	exit 1
fi
if [ -d "$legacy_venv" ]; then
	rm -rf -- "$legacy_venv"
fi
SHAZAMCAPTURE_INIT_EOF
chmod +x custom-init.sh
```

The canonical source is [`docker/custom-init.sh`](../docker/custom-init.sh).
The release verifier checks that the pasted script matches it exactly.
