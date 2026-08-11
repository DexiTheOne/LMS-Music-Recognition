# Milestone 1 technical note

## Installed build and verified boundary

Inspected read-only application source for Lyrion Music Server **9.1.0**,
revision **1771315634** (2026-02-19), on macOS.

Player response path:

1. `Slim::Web::HTTP::sendStreamingResponse($httpClient)` resolves the physical
   player using its private HTTP-connection map.
2. For a non-file player stream it calls
   `$client->nextChunk(MAXCHUNKSIZE, $retry_callback)`.
3. `Slim::Player::Client::nextChunk($client, $max_bytes, $retry_callback)`
   returns a scalar reference containing output from the active song source,
   including transcoder output where applicable.
4. `sendStreamingResponse` queues that exact reference and later calls
   `syswrite` with offset/length flow control.

The runtime wrapper is therefore on `Slim::Player::Client::nextChunk`. It calls
the original first and copies a successful scalar-ref return without mutation.
It preserves scalar/list/void context and exceptions. Attribution comes from
the method's physical `$client`, not URL or a synthetic player. Local `file://`
tracks are discarded.

Observed bytes within five seconds are positive proof of proxying. Playing
without observations for fifteen seconds is classified direct; transitional
states are unknown and fail closed.

## UI integration and client differences

`Slim::Menu::TrackInfo` is the verified extension point for the current
track/player **More** menu. The item follows LMS's Radio Artwork pattern: a
plain label, callback URL, and `nextWindow => 'parent'`. The callback returns
one `showBriefly` / `nowPlaying` item after accepting recognition.

| Concern | Jive | Material Skin | SB2 |
|---|---|---|---|
| Action | Direct list action | Direct list action | URL callback only; no control-UI action metadata |
| Progress | Native inline wheel on the selected row | Native three-dot loader | Native block animation |
| Completion | Child result window; manual Back | Scoped terminal list response | Replacement `line` display |
| Match layout | Title, artist, album lines | `Title - Artist - Album` | Display lines |

The SB2 distinction is structural, not merely a completion-time condition.
Traditional rows must contain only the callback URL and
`nextWindow => 'parent'`. If they also expose `jive` actions or `itemActions`,
SB2 executes `shazamcaptureui items` without a request source or connection,
skips the callback that supplies `isButton`, and can finish in an empty
XMLBrowser page. The defensive direct-command fallback classifies
`origin=auto` plus no source as `button`, returns an `items` array, and then
uses the same two-line `showBriefly` display.

The recognition session has an overall deadline derived from its sample,
worker, retry-delay, and retry-sample budgets. The direct UI request has an
independent deadline five seconds longer. Playback cancellation also completes
manual UI requests, so progress is always replaced by a match, no-match, or
error.

## Settings integration

The web UI registers two native `Slim::Web::Settings` pages when `main::WEBUI`
is available:

- `Settings.pm` provides the server-wide plugin settings page and persists the
  history display, same-stream metadata, sample duration, retry count, retry sample
  duration, retry delay, automatic recognition, overlay, all-no-match overlay
  clearing, station ignore list, automatic cooldown, and active history database preferences in
  `plugin.shazamcapture`. It also handles independent database selection,
  backup, and guarded clear actions outside the ordinary preference-save path.
- `PlayerSettings.pm` uses `needsClient` and client-scoped plugin preferences
  to configure the history scope, text filter, sort order, and optional
  plugin-relative read-only database view independently for each player. Its
  `selectFile selectFile_sqlite3` classes invoke LMS's native file browser;
  `beforeRender` supplies an absolute picker location, and the save handler
  normalizes valid selections back to a portable relative path.

Recognition defaults to a 10-second initial sample, one additional attempt, one
required confirmation (the first match is accepted), a 10-second retry sample,
and a five-second retry delay. Sample durations are limited to 5–30 seconds,
retry count to 0–10, consecutive confirmations to 1–11, and delay to 1–30
seconds. Pending confirmation uses the same retry budget and delay as a
no-match. A different match resets the consecutive streak to one; a no-match
resets it to zero.
Every attempt snapshots the newest requested audio from the fixed 30-second
PCM ring and passes that same duration to Shazamio's signature generator.
No-match results remain internal until retries are exhausted. Retries use LMS
timers, require newly captured PCM, and stop on worker errors, stream
generation changes, or PCM epoch changes.
An automatic result is marked as exhausted without a valid match when the
configured retry budget completes without an accepted, confirmed song. The
optional default-off overlay-clear preference restores native station metadata
for any non-stale automatic terminal result without a valid match, including
no-matches, early retry termination, and recognition failures, when the
two-no-result confirmation bypass is disabled. Enabling that bypass preserves
the prior overlay. Stale results and manual requests also leave it intact.

Automatic overlay artwork is composed by a separate external artwork worker,
never on the LMS event loop. It downloads the already-selected Shazam cover,
normalizes it to a square JPEG, and burns a translucent bottom bar containing
the original station name into the pixels. Storage is bounded to one
plugin-local `var/tmp` image per player, atomically replaced on a later match
and removed when that player's overlay clears. A plugin HTTP handler serves
the current image with a versioned absolute URL derived from LMS's runtime
server address and `no-store`. The absolute URL is required so LMS core sends
remote-player and control-UI cover requests through its normal image proxy
rather than treating the plugin-relative value as a filesystem path.
Download, decoding, or composition failure falls back to the original remote
artwork. If LMS has only a raw URL rather than a friendly station title, the
label uses `Radio - hostname` and never prints the full stream URL into the
artwork.

The atomic destination replacement is also the authoritative completion
signal. LMS can reap a short-lived artwork child before its timer observes the
process exit status; a changed file identity is safe to accept because the
helper performs the rename only after download, decode, text rendering, and
JPEG output have all completed successfully.

Numeric settings must use LMS's enhanced slider-input convention rather than
raw HTML `type="number"` controls. Use a text input with `stdedit` and a
`sliderInput_MIN_MAX_STEP` class, for example:

```html
<input type="text" class="stdedit sliderInput_5_30_1"
    name="pref_sampleSeconds" value="[% prefs.sampleSeconds | html %]"
    size="3" />
```

This lets LMS and Material-style settings pages render the native slider and
keeps new numeric controls visually consistent. Continue validating and
clamping values in `Settings.pm`; the slider is presentation, not a security
or correctness boundary.

The Spotify preference defaults on and is evaluated whenever a history detail
feed is built. Turning it off suppresses only the Spotify UI row; recognition,
normalization, and the `spotify_url` database column remain active. The
per-player database path remains saved while **Use current history database**
disables its input.

## Recognition history and URL normalization

Only successful matches are appended to the active direct `var/*.sqlite3`
database, defaulting to `var/history.sqlite3`; no-match and failed attempts
remain in LMS logs. Each event records player identity, radio
station, technical playback source, localizable timestamp, normalized song
metadata, and the external URLs returned by Shazam. An identical consecutive
match on the same player is suppressed for ten minutes, while later
recognitions of the same song remain separate events.

The **Shazam History** OPML app applies the initiating player's saved history
scope, case-insensitive field filter, and whitelisted sort order using bound
SQLite parameters. It normally queries the active writable handle. An optional
plugin-confined path is instead opened with SQLite's read-only flag for the
duration of one feed request; it never replaces the active handle used by
`record`. Canonical path checks reject traversal and symlink escapes. A native
browse textarea summarizes the alternate database, when present, and the
active settings above the rows. The app lists the song title and remote
artwork. If Shazam supplies no artwork, the row uses LMS's
`html/images/cover.png` rather than downloading or storing a local thumbnail.
Detail pages expose all stored metadata. Apple Music, Spotify, and Shazam rows
use LMS's `weblink` field so Material Skin can open them.

History stores `trigger_method` as `auto` or `manual`; detail pages render
those stable values as **Auto Sample** and **Manual Sample**. Additive
migration marks all rows created before this field existed as manual.

The global settings page lists only validated `.sqlite3` files directly under
`var`, can create and switch to a new database, and keeps the previous
connection active if a selection cannot be opened and migrated. Backups use
DBD::SQLite's online-backup API so committed WAL content is included, run an
integrity check, finalize as a standalone SQLite file, and are stored under
`var/backups`. Clearing is refused unless that backup succeeds and the
confirmation control is submitted; it removes history rows and resets the
table sequence without changing other databases or plugin preferences.

`Auto.pm` owns independent per-player timers for Radio and `hlspl` sources,
applies the station ignore list, starts fresh automatic recognition cycles,
schedules the post-cycle cooldown, and publishes generation-bound metadata
overlays without using LMS's synthetic `playlist newsong` title-update path.

Apple Music links are forced to HTTPS and have query strings and fragments
removed. Spotify web links, Android `intent://` links, and
`spotify:track:`/`spotify://track/` app URIs are canonicalized to tracking-free
`https://open.spotify.com/track/...` URLs. If Shazam provides no Spotify link,
the detail page displays **No Spotify Link Returned**. Older history rows are
preserved; fields unavailable when they were recorded remain empty.

## Current empirical state

Live LMS, plugin-local FFmpeg, persistent PCM capture, and real Shazam
recognition have been verified. SpotOn/Ogg successfully identified “Juicy” by
Emmett Kai. The full source/player matrix in `TESTING.md` remains incomplete;
do not infer success for every codec, topology, or failure mode.
