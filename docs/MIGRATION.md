# Linux and macOS migration

Shazam Capture supports LMS 9.1.x on Linux and macOS. Its process supervision
uses POSIX `fork`, pipes, signals, and nonblocking file descriptors; Windows is
outside the supported scope.

## Copy the plugin

Copy the plugin directory while excluding host-specific and transient content:

```text
python/venv/
var/tmp/
var/logs/
```

The virtual environment must be rebuilt on the destination. A macOS virtual
environment and its FFmpeg executable cannot run on Linux, and binaries may
also differ between CPU architectures.

To retain recognition data, copy these separately and preserve ownership:

```text
var/*.sqlite3
var/backups/
var/dumps/
```

Generated SQLite `-wal` and `-shm` sidecars should not be used as backups. Use
the plugin's verified backup action before migration when possible.

## Rebuild the destination runtime

From the destination plugin root, using a Python 3.12 interpreter:

```bash
python3.12 -m venv python/venv
python/venv/bin/python -m pip install -r python/requirements.txt
python/venv/bin/python -m pip check
python/venv/bin/python -c \
  'from shazamio import Shazam; import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
```

Use the destination system's actual Python 3.12 command or absolute path for
the first command. Do not install packages globally. The plugin always derives
its own root and normally uses:

```text
python/venv/bin/python
python/venv/lib/python*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*
```

The LMS service account must be able to execute those files and write beneath
the plugin's `var` directory.

## Optional service overrides

Sites with intentionally external executables may set absolute paths in the
LMS service environment:

```text
SHAZAMCAPTURE_PYTHON=/absolute/path/to/python
SHAZAMCAPTURE_FFMPEG=/absolute/path/to/ffmpeg
```

These are optional. If an override is present but is not executable, the plugin
reports the configuration error and does not silently select another
executable.

## Verify after LMS starts

The selected player's CLI status includes a `runtime` object:

```text
<playerid> shazamcapture status
```

For the standard plugin-local installation, expect:

```json
{
  "python_ready": 1,
  "python_source": "plugin",
  "ffmpeg_ready": 1,
  "ffmpeg_source": "plugin"
}
```

Also confirm the startup log reports that the `nextChunk` hook was installed.
Recognition still requires proxied playback, outbound HTTPS access, and the
supported LMS 9.1.x data path.
