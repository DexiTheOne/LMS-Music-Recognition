# Upgrade findings and checks

These findings came from the Docker-hosted LMS upgrade through Shazam Capture
0.3.8. A reported plugin version alone did not prove that its settings page or
translations were current.

## Before an upgrade

1. Record the active database and `history_entries` from `shazamcapture status`.
2. Use the plugin's **Create backup** action. It makes a consistent SQLite
   backup under the plugin's `var/backups` directory.
3. Copy that backup to persistent storage **outside**
   `/config/cache/InstalledPlugins/Plugins/ShazamCapture`. LMS's Plugin
   Downloader removes that entire directory during an upgrade, including
   `var` and any backups left there. Do not copy a live SQLite database as a
   substitute for the plugin's backup action.
4. Keep the current `/config/custom-init.sh` from
   [`docker/custom-init.sh`](../docker/custom-init.sh). Its Python environment
   belongs at `/config/cache/ShazamCapture-venv`, outside the directory LMS
   replaces. From `/config`, the exact paste-ready update is in
   [`CUSTOM-INIT-PASTE.md`](CUSTOM-INIT-PASTE.md).

During the 0.3.5 upgrade, Plugin Downloader reported at least 453 failed file
unlinks and 93 failed directory removals under the old plugin-local
`python/venv`. The revised init script creates and checks the external
environment before removing that old generated environment. It does not back
up recognition history.

## After an upgrade

1. Check `shazamcapture status`. On the Docker installation, both
   `python_source` and `ffmpeg_source` should be `cache`, with paths beneath
   `/config/cache/ShazamCapture-venv`.
2. Compare `history_entries` with the value recorded before upgrading. In the
   observed 0.3.6 transition it fell from 16 to 0; the active settings page
   then showed a new `history.sqlite3` with 0 entries. The cause and recovery
   of those earlier entries were not verified. Restore from an external
   backup or volume snapshot if needed before treating the new database as
   complete.
3. Open the global settings page. Verify the station-artwork control reads
   **Show the radio station name on recognized artwork**, with an ordinary
   checkbox and readable help text. A raw `PLUGIN_SHAZAMCAPTURE_...` key is a
   translation-cache problem; a missing control is a template problem.

## Why the page and strings could lag behind the reported version

- **Compiled templates:** LMS keeps compiled settings templates under its
  cache directory. Earlier release ZIPs stamped every file with January 2000,
  so a compiled 0.3.0 page could appear newer than a freshly extracted 0.3.6
  template. From 0.3.7, the package includes version-specific `basic` and
  `player` template paths; the settings handlers select those paths.
- **Translated strings:** LMS keeps a parsed `stringcache.*.bin` and checks
  source-file modification times. The same fixed timestamp let it reuse
  translations from before the station-artwork control existed. From 0.3.8,
  packaged `strings.txt` has a reproducible timestamp that changes with the
  release version. The release verifier checks it.

The raw-key problem was resolved on the running server by refreshing only the
generated string cache. From inside `/config`, the verified command was:

```sh
grep -q 'PLUGIN_SHAZAMCAPTURE_AUTO_STATION_ARTWORK_LABEL' \
  cache/InstalledPlugins/Plugins/ShazamCapture/strings.txt &&
rm -f cache/stringcache.*.bin
```

Restart the container after that command so LMS loads the strings again. The
`grep` guard prevents clearing the cache if the installed plugin does not
contain the label. This is a recovery step for an already stale cache; normal
upgrades to 0.3.8 and later should refresh it through the package timestamp.

## Release checks

Run `tools/build-release.sh` and `tools/verify-release.sh`. The verifier checks
the package checksum, version-specific settings copies, version-specific
`strings.txt` timestamp, excluded runtime files, and the paste-ready Docker
script. After publishing, compare the downloaded release ZIP with the local
build and confirm `repo.xml` points to that same ZIP and SHA-1.
