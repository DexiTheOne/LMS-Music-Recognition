# Shazam Capture (milestone 1)

Diagnostic LMS 9.1.0 plugin which copies bytes already being proxied to the
original physical player. It never opens the source URL, changes player
preferences, joins sync groups, or controls playback.

## Install from the LMS Plugins page

Add this custom repository URL under **Settings → Plugins → Additional
Repositories**:

    https://raw.githubusercontent.com/DexiTheOne/LMS-Music-Recognition/main/repo.xml

After LMS refreshes the repository list, select **Shazam Capture**, apply the
change, and allow LMS to restart. The repository release is a versioned ZIP
whose `install.xml` is at the archive root and whose SHA-1 is verified by LMS.

Recognition also needs Python and FFmpeg. For the official LMS Docker image,
install the operating-system prerequisites and build the plugin-local virtual
environment with the supplied [`docker/custom-init.sh`](docker/custom-init.sh).
Copy it to `/config/custom-init.sh` on the Docker host and make it executable.
The script is safe to run on every container start and completes the Python
environment after the plugin has been installed. On the first installation,
restart the container once after LMS installs the plugin so the script can see
the new plugin directory. See [`docs/INSTALL.md`](docs/INSTALL.md) for the
complete procedure and architecture-independent alternatives.

CLI:

    <playerid> shazamcapture status
    <playerid> shazamcapture reset
    <playerid> shazamcapture dump
    <playerid> shazamcapture recognize
    <playerid> shazamcapture recognizefresh
    <playerid> shazamcapture overlay
    <playerid> shazamcapture history

`recognize` returns immediately with `started: 1`; poll `status` for
`worker_running` and `last_result`. `recognizefresh` uses the same recognition
session but always clears the PCM ring and collects a new initial sample,
regardless of the global manual sample setting. It is intentionally available
only through CLI and the plugin API; UI buttons continue to use `recognize`.

The global settings page controls the manual identification sample mode,
initial sample length, number of additional attempts, consecutive match
confirmations, retry sample length, and delay between retries. A confirmation
value of 1 accepts the first match; higher values require the same Shazam result
on that many consecutive attempts within the configured retry budget.
**Buffered sample** uses recent PCM and
waits if necessary until the configured initial duration is available.
**Fresh sample** clears only the PCM ring after a request is accepted, waits
for the same configured duration, and then analyzes it.
FFmpeg and capture continue normally in both modes. Every retry uses the newest
configured slice of the fixed 30-second PCM ring. A no-match reaches the UI
only after all configured retries have been exhausted; worker errors are not
retried.

Successful recognitions are appended to the selected plugin-local SQLite
database in `var`; `var/history.sqlite3` is the default. Each row includes the
player, radio source, recognition
time, playback plugin/technical source, song metadata, Apple Music, Spotify,
and Shazam links, and a remote artwork URL.
No-match and failed attempts remain in LMS logs and are not stored. An
immediately repeated match on the same player is suppressed for ten minutes;
the same song recognized later is retained as a new event. Use `limit` and
`offset` parameters with the `history` command to page through results; the
maximum page size is 500.
Recognition artwork is not stored locally. Recognition audio is not stored
unless the global debug WAV setting is enabled.

Other LMS plugins can start the same asynchronous manual-recognition path
through `Plugins::ShazamCapture::API`. The caller supplies a physical player
ID, its plugin identifier, and a completion callback; optional reason, opaque
callback context, and request ID fields are supported. Successful API matches
store the caller and reason in history. Call `recognize_fresh` instead of
`recognize` to force collection of a fresh initial sample without changing the
global setting. See [`docs/API.md`](docs/API.md) for the complete contract and
example.

The synchronous `Plugins::ShazamCapture::API->overlay(player_id => $id)` call
and `<playerid> shazamcapture overlay` CLI command return the metadata currently
published by automatic recognition. Both return an explicit error when that
player has no active automatic overlay. They only inspect plugin state and do
not republish metadata or affect playback.

Optional automatic recognition is limited to LMS Radio and `hlspl` sources.
Each physical player has an independent recognition cycle and cooldown. Plugin
sources such as Spotty are excluded. A comma-separated station ignore list can
disable automatic sampling by LMS station name. When the separate metadata
overlay option is enabled, successful automatic samples temporarily replace
the radio title, artist, album, and artwork; manual samples never publish an
overlay. Recognized artwork can include a translucent bottom bar naming the
original radio station; this default-on behavior has its own settings toggle.
The plugin keeps only one generated JPEG per player,
overwrites it on the next match, and removes it when the overlay is cleared.
For an unnamed raw stream, the bar identifies its host instead of displaying
the full URL. If artwork composition fails, the unmodified Shazam artwork is
used. Composition failures are logged in the LMS server log and in the latest
per-player `var/logs/artwork_PLAYER_ID.log` diagnostic file. A separate
default-off option restores the station's original metadata
when every attempt in an automatic sequence returns no match. The next
successful automatic sequence publishes a new overlay.
While automatic recognition is active, the Track Info row shows a concise
terminal failure from the latest sequence, including **No Match Found** after
all retries return no result. The message clears when the next sequence starts;
successful sequences leave the normal **Auto Recognition is on** label.

The LMS **My Apps** menu includes **Shazam History**. Each player's plugin
settings can independently limit the view to that player, apply a
case-insensitive text filter by station, stream source, artist, song title,
album, capture type, API caller, or API reason, and choose chronological or
alphabetical ordering.
The per-player page can also point the view at a plugin-local `.sqlite3`
snapshot, normally beneath `var/backups`; snapshots are opened strictly
read-only while recognition continues writing to the active database. The path
field uses LMS's built-in file selector filtered to `.sqlite3` files. A valid
absolute picker result is saved in plugin-relative form. The active backup
path, scope, filter, and sort appear above the history rows.
Selecting a song opens its full metadata, source, player, time, sample type,
API caller and reason when applicable, and external links. Missing artwork
uses LMS's default cover image, and missing Spotify results are labeled
**No Spotify Link Returned**.

Apple Music and Spotify URLs are normalized before storage. Tracking query
parameters and fragments are removed; Spotify app and intent links are
converted to clickable `https://open.spotify.com/track/...` URLs.

## UI

The selected track/player **More** menu includes **Recognize Song**. It is a
terminal action, not a submenu. LMS's native loading animation remains visible
until the match, **No song found**, or an error is available.

Jive shows its inline wheel in place of the selected row's arrow, then opens a
child window containing the terminal result; the user returns with Back.
Material Skin receives the result on the initiating browser response without
opening that child window, and SB2 displays the artist on its small top line
and title on its large bottom line. Results are sent only to the UI path that
started recognition. A separate UI deadline prevents a native loader from
remaining active if the normal recognition callback path faults.
SB2 deliberately receives only the traditional callback row; direct
control-UI action metadata is reserved for Jive and Material Skin.

## Settings

LMS exposes a global **Shazam Capture** page under plugin settings and a
**Shazam Capture** page under each player's settings. The global page includes
**Show Spotify information in Shazam History**, enabled by default. Disabling
it hides both Spotify links and the missing-link message from history detail
pages without changing recognition, URL normalization, or database storage. It
also offers default-off options to remove the automatic metadata overlay
after a sequence ends without a valid confirmed song, including a stopped
retry sequence or recognition failure, and to
**Save recognition audio for debugging**. **Accept the first match after two
no-results** changes confirmation behavior only and does not suppress overlay
clearing after an unsuccessful sequence.
When enabled, every exact normalized WAV submitted to Shazam is retained in
`var/dumps`, named from the returned title (or `NoResult`) and local date/time.
These files are retained until manually deleted. The page can also select or
create a direct `var/*.sqlite3` history database, create a verified timestamped
snapshot in `var/backups`, and back up then clear every recognition from the
active database. Backups and SQLite sidecar files are not selectable. The page
also configures buffered/fresh manual sampling, initial and retry sample
lengths, no-match retry count, and retry delay. Numeric settings use LMS's
native enhanced slider convention
(`stdedit sliderInput_MIN_MAX_STEP`) rather than browser-native number inputs,
so future numeric settings should follow the same pattern. The per-player page
configures its history scope, filter, sort, and optional read-only database
view independently of every other player.

## Dependencies

Linux and macOS are supported. Dependencies are installed in the plugin-local
environment; do not copy `python/venv` between operating systems or CPU
architectures. The `imageio-ffmpeg` package supplies a plugin-local FFmpeg
binary.

    python3.12 -m venv "python/venv"
    "python/venv/bin/pip" install -r "python/requirements.txt"

The worker uses `python/venv/bin/python` by default. The LMS service environment
may set `SHAZAMCAPTURE_PYTHON` or `SHAZAMCAPTURE_FFMPEG` to an absolute
executable path when a site needs an explicit override. An invalid explicit
override fails closed and is reported by `shazamcapture status`; it never falls
back silently to a host-specific location. See `docs/MIGRATION.md` for a
Mac-to-Linux copy procedure.

Encoded dumps are disabled in code by default. They contain copyrighted audio
and must be enabled deliberately for development.

Python 3.12 is intentional: the native `shazamio-core` build currently crashes
when imported under the installed Python 3.14 runtime.

See `docs/TECHNICAL-NOTE.md` for the verified interception path and limitations.
