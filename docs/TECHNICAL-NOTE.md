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
| Action | Native callback item | Native callback item | Native callback level |
| Progress | Native inline wheel on the selected row | Native three-dot loader | Native block animation |
| Completion | Jive-only `popupplay` | Scoped terminal list response | Replacement `line` display |
| Match layout | Title, artist, album lines | `Title — Artist — Album` | Display lines |

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
  duration, retry delay, automatic recognition, overlay, station ignore list,
  and automatic cooldown preferences in `plugin.shazamcapture`.
- `PlayerSettings.pm` uses `needsClient` to provide the per-player page.

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
per-player page remains an informational placeholder.

## Recognition history and URL normalization

Only successful matches are appended to `var/history.sqlite3`; no-match and
failed attempts remain in LMS logs. Each event records player identity, radio
station, technical playback source, localizable timestamp, normalized song
metadata, and the external URLs returned by Shazam. An identical consecutive
match on the same player is suppressed for ten minutes, while later
recognitions of the same song remain separate events.

The **Shazam History** OPML app lists the song title and remote artwork. If
Shazam supplies no artwork, the row uses LMS's `html/images/cover.png` rather
than downloading or storing a local thumbnail. Detail pages expose all stored
metadata. Apple Music, Spotify, and Shazam rows use LMS's `weblink` field so
Material Skin can open them.

History stores `trigger_method` as `auto` or `manual`; detail pages render
those stable values as **Auto Sample** and **Manual Sample**. Additive
migration marks all rows created before this field existed as manual.

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
