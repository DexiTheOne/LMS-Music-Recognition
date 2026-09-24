# Install Shazam Capture from an LMS custom repository

## What LMS installs

LMS custom repositories are XML documents that point to versioned ZIP files.
For a server plugin, the repository `name` must match the Perl package folder,
the version must match `install.xml`, and the ZIP must contain `install.xml` at
its root. LMS downloads the archive, verifies its SHA-1, extracts it below its
cache `InstalledPlugins/Plugins` directory, and activates it after a restart.

This project publishes `repo.xml` from the default branch and attaches the
versioned ZIP to the corresponding GitHub release. Add this URL under
**Settings → Plugins → Additional Repositories**:

    https://raw.githubusercontent.com/DexiTheOne/LMS-Music-Recognition/main/repo.xml

Select **Shazam Capture**, apply the change, and allow LMS to restart.

## Official LMS Docker image

The plugin archive is portable source and intentionally does not contain the
developer's virtual environment: Python environments and bundled FFmpeg
binaries cannot safely be copied between macOS/Linux or CPU architectures.
The official `lmscommunity/lyrionmusicserver` image supports a persistent
`/config/custom-init.sh` hook for additional packages.

1. Copy `docker/custom-init.sh` from this repository to the host directory
   mounted as `/config/custom-init.sh`.
2. Make that file executable on the host.
3. Restart the container. This installs Python but exits harmlessly if the LMS
   plugin has not been installed yet.
4. Add the repository URL in LMS and install **Shazam Capture**.
5. After LMS has restarted to install the plugin, restart the container once.
   The init script creates `/config/cache/ShazamCapture-venv`, installs the pinned dependency ranges,
   and obtains the matching `imageio-ffmpeg` binary for the container CPU.
6. In LMS, run `<playerid> shazamcapture status` through the CLI and confirm
   both `python_ready` and `ffmpeg_ready` are `1`.

The virtual environment lives below `/config/cache`, outside
`InstalledPlugins/Plugins/ShazamCapture`, so LMS can replace the plugin during
upgrades. The script also installs Fontconfig and a
DejaVu font for FFmpeg's station-name artwork label. It checks dependencies on
later starts, which also repairs the environment after an LMS plugin upgrade
replaces the installed directory.

### Upgrade from a plugin-local virtual environment

Replace the existing `/config/custom-init.sh` with the current
`docker/custom-init.sh` and restart the container **before** requesting the
next plugin upgrade. The updated script builds and checks the external
environment, then removes only the old generated
`InstalledPlugins/Plugins/ShazamCapture/python/venv` directory. LMS can then
replace its plugin directory normally. This one-time cleanup does not touch
recognition history, backups, audio dumps, or plugin preferences. The old
plugin code cannot discover the new environment, so recognition may be
temporarily unavailable between this restart and the 0.3.6 upgrade; playback
is unaffected. Upgrade promptly, then confirm `python_source:cache` and
`ffmpeg_source:cache` in `shazamcapture status`.

For a single block to paste while already in `/config`, use
[`CUSTOM-INIT-PASTE.md`](CUSTOM-INIT-PASTE.md).

If an earlier upgrade left a mixed installation, reinstall the new release
after that restart and check that the settings page includes **Show the radio
station name on recognized artwork**. If the init script cannot remove the
legacy environment, resolve its file ownership before retrying the upgrade.

If the container does not run as root during `custom-init.sh`, bake `python3`,
`python3-venv`, CA certificates, Fontconfig, and at least one usable font into a
derived image instead. Then create the virtual environment from
`python/requirements.txt` outside the installed plugin directory and set
`SHAZAMCAPTURE_PYTHON` to its absolute interpreter path in the LMS service
environment. Do not copy the
macOS development environment to Linux.

## Release procedure

The release archive is generated, not assembled by hand:

    tools/build-release.sh
    tools/verify-release.sh

The builder reads the version from `install.xml`, creates
`dist/ShazamCapture-VERSION.zip`, calculates SHA-1, and writes `repo.xml` from
`tools/repo.xml.in`. Release checklist:

1. update `install.xml`, the changelog, and repository change text;
2. build and verify the release;
3. commit `repo.xml` with the source changes;
4. tag the commit as `vVERSION` and push the branch and tag;
5. create the matching public GitHub release and upload the generated ZIP;
6. fetch the public `repo.xml` and ZIP URLs and verify the published checksum.

The version number is part of the archive filename because LMS and HTTP caches
can otherwise reuse an older download during upgrades. To request inclusion in
LMS's default third-party list, add this repository XML URL to the
LMS-Community `lms-plugin-repository` project's `include.json` in a separate
pull request. A custom repository does not require that upstream inclusion.

## References

- [Lyrion repository developer reference](https://preview.lyrion.org/reference/repository-dev/)
- [LMS-Community repository aggregator](https://github.com/LMS-Community/lms-plugin-repository)
- [Official LMS Docker image and custom init hook](https://hub.docker.com/r/lmscommunity/lyrionmusicserver)
