# Changelog and failure history

## 2026-07-28 — Native history database file selector

- Added LMS's native file-browser classes to the per-player history database
  input and restricted the picker to `.sqlite3` files.
- Rendered valid saved paths as absolute server paths so the built-in browser
  opens at the selected file or the plugin's `var/backups` directory.
- Normalized valid absolute selections inside the plugin back to portable
  plugin-relative saved paths. Canonical confinement still rejects external
  files and symlink escapes.

## 2026-07-28 — Per-player read-only history database views

- Added a default-on **Use current history database** per-player option and a
  retained plugin-relative `.sqlite3` path which defaults to `var/backups/`.
- Alternate databases are opened through a separate SQLite handle using the
  read-only open flag. Manual and automatic recognition continue writing only
  through the active writable history handle.
- Confined alternate paths to canonical files within the plugin directory,
  rejecting absolute paths, traversal, missing files, directories, and
  symlinks that resolve outside the plugin.
- Applied the existing player scope, text filter, and sort controls to
  alternate databases, and added the backup path to the native history summary
  only while an alternate database is selected.
- Added concise history-row errors for missing, invalid, unreadable, and
  incompatible databases without changing the active database.

## 2026-07-28 — Optional overlay clearing after automatic no-match

- Added a default-off global option to restore the station's original metadata
  when an automatic sequence exhausts its retries without a valid confirmed
  song. A later successful sequence publishes the recognition overlay again.
- Enabling **Accept the first match after two no-results** preserves the prior
  overlay after an unsuccessful sequence. Manual recognition, errors, stale
  results, and early retry termination also leave it intact.

## 2026-07-28 — Per-player history views

- Added independent per-player Shazam History settings for current-player
  scope, filter field and value, and sort order.
- Added case-insensitive partial filtering by station, stream source, artist,
  song title, album, or capture type. Filter columns and sort expressions are
  whitelisted, values use bound parameters, and literal `%` and `_` characters
  are treated as text rather than SQL wildcards.
- Added newest/oldest, artist A-Z/Z-A, and song-title A-Z/Z-A ordering with
  stable secondary ordering.
- Disabled and cleared the filter value when **No filter** is selected. An
  empty value also behaves as no filter.
- Added a native browse summary above Shazam History showing either **All
  players** or the selected player's display name, the active filter, and the
  sort order.

## 2026-07-28 — History database management

- Added a global-settings database selector for existing direct
  `var/*.sqlite3` files plus a guarded new-database name field. Invalid,
  missing, or non-SQLite selections leave the current connection active.
- Persisted the active database filename with `history.sqlite3` as the startup
  fallback. Backups and SQLite WAL/SHM sidecars never appear in the selector.
- Added an online SQLite backup action that captures committed WAL content,
  verifies database integrity, and writes a standalone timestamped snapshot
  beneath `var/backups`.
- Added a confirmation-gated **Back up and clear database** action. Clearing
  aborts unless its backup succeeds, removes only the active database's
  recognition rows, resets its sequence, checkpoints WAL, and vacuums it.

## 2026-07-28 — Jive inline recognition progress

- Split successful Jive child-window results into three inert rows ordered as
  song title, artist, and album. Material and traditional-player result
  formatting remain unchanged.
- Fixed named SqueezePlay/Jive TrackInfo requests being misclassified as
  Material. The retained direct-command transport is now authoritative:
  JSON-RPC routes to Material, while SqueezePlay/Comet routes to Jive.
- Jive's direct action remains processing so its native inline wheel replaces
  the row arrow until completion. Its action deliberately omits `nextWindow`,
  so SqueezePlay then opens the terminal result as a child window with a
  manual Back action. Material alone retains `parentNoRefresh`; SB2 remains on
  its traditional callback/display path.
- Wrapped the existing TrackInfo items dispatch to retain its request transport
  while the row is built. This separates Jive's child-window action metadata
  from Material's non-navigating action even when both request named menu
  modes.
- Fixed Jive still returning Home despite its action omitting `nextWindow`.
  SqueezePlay falls back to the row's top-level `nextWindow => 'parent'`;
  Jive's generated row now omits that traditional-button navigation value as
  well. Material retains its action-level `parentNoRefresh`, and traditional
  clients retain the row-level `parent`.
- Captured the active request around LMS's common request executor. SqueezePlay
  can retain TrackInfo request objects whose handler pointer predates plugin
  initialization, so replacing either the dispatch or TrackInfo handler could
  not affect them. The executor remains dynamically resolved and exposes the
  initiating transport while the provider synchronously builds its row.
- Fixed Jive repeatedly issuing recognition requests instead of settling the
  completed child menu. The terminal response now includes the required
  `offset => 0` paging metadata alongside `count => 1`, and its sole result row
  is explicitly non-actionable.
- Fixed TrackInfo feed provenance overriding Jive navigation. The final
  recognition-row action is now adjusted while XMLBrowser serializes it for a
  concrete connection: SqueezePlay/Comet always receives no `nextWindow` at
  either level, while JSON-RPC always receives action-level
  `parentNoRefresh`. This remains correct even when the feed was built or
  cached without the initiating request transport.
- Stopped treating a source-less `menu=track` request as Material. SqueezePlay
  can rebuild TrackInfo through exactly that internal request shape. Such
  control rows now remain navigation-neutral; only explicit JSON-RPC receives
  `parentNoRefresh`, and only a request without control-menu mode receives the
  traditional-button row-level `parent`.
- Retained the neutral direct action on source-less control-menu rows.
  SqueezePlay can select that cached row after its Jive-specific refresh;
  keeping the action lets the live Comet request receive the populated paged
  result instead of falling back to an empty URL-callback child page.
- Made traditional-button completion authoritative before Material routing.
  SB2 results now always schedule the native two-line `showBriefly` display,
  even when TrackInfo's menu-mode hint resembles a Material request.
- Stopped advertising control-UI list actions on traditional TrackInfo rows.
  SB2 now follows the row's URL callback, which supplies `isButton` and returns
  the native `showBriefly` payload. A source-less direct-command fallback also
  returns the `items` array expected by XMLBrowser before showing the result.
- Added a UI-request watchdog slightly beyond the recognition-session
  deadline. It completes the pending action with an error and cancels a
  stranded manual recognition, preventing an endless inline wheel even if the
  normal recognition callback path faults.
- Sanitized recognition popup text before returning it to control UIs. HTML
  markup, entities, control characters, and repeated whitespace are normalized
  to plain text so Material does not display literal tags.
- Replaced the UTF-8 em-dash separator with an ASCII hyphen, avoiding mojibake
  in LMS UI paths which do not consistently preserve Perl source encoding.
- Prevented Material Skin from wrapping the sole terminal text row in its
  browse-page `<div style="...">` decoration before forwarding that row to the
  escaped snackbar. The terminal row now carries inert navigation metadata,
  while the initiating action continues to control the actual navigation.

## 2026-07-27 — Optional confirmation bypass after two no-matches

- Added a default-off global toggle that disables consecutive confirmation for
  the remainder of a recognition request when its first two Shazam attempts
  both return no match.
- When enabled, the next valid match is accepted immediately. A match among the
  first two attempts, worker errors, and stale results do not activate the
  bypass.

## 2026-07-27 — Native cross-client recognition action

- Fixed Material/Jive origin routing by encoding the TrackInfo context in fixed
  parameters on a direct control-UI action. Named modes are Material; numeric
  `menu=1`, which both Material and Jive use, is resolved by the direct
  command's retained request source (JSON-RPC for Material, Comet for Jive).
  XMLBrowser re-fetches callback rows with
  `menu=trackinfo`, supplies no callback query, and uses a globally cached
  TrackInfo feed; relying on the callback closure caused Material results to
  leak to Jive while Material fell back to the **Recognize Song** item label.
- Material's explicit action is list-shaped (`shazamcaptureui items`) so its
  native `fetchingItem` state displays the three-dot loader for the lifetime of
  the pending request. Its terminal response contains one result text row and
  uses `parentNoRefresh`, so Material stays on the current view and displays
  the result rather than synthesizing a popup from the original row label.
  Missing or malformed action origins fail toward Material rather than leaking
  a physical player popup to Jive.
- Mark the direct recognition request as processing before starting
  asynchronous work. Without that state LMS completed JSON-RPC immediately,
  so Material removed its three-dot loader while recognition continued in the
  background.
- Classify every named TrackInfo menu mode as Material. Material can enter the
  More menu through several named modes, so enumerating only `nowhere` and
  `track` still misrouted some launches.
- Earlier testing incorrectly concluded that Jive had no native generic inline
  spinner for an ordinary pending menu callback. SqueezePlay does show an
  inline wheel for the lifetime of its pending direct action.
- Removed Material **Listening** and keep-alive notifications. The native menu
  callback now remains pending, leaving Material's three-dot loader visible
  until a match, no-match, or error completes it.
- Removed the Jive **Listening** popup. Pending callbacks expose LMS's native
  block/loading animation on SB2; Jive has no equivalent for ordinary actions.
- Added initiating-path result routing. SB2 gets artist on its small top line
  and title on its large bottom line; Jive gets its popup; Material gets the
  terminal response only on the browser connection that initiated it.
- Replaced the custom Jive command/style with LMS's native callback-menu
  pattern used by Radio Artwork.
- Added terminal completion for every match, no-match, cancellation, or error
  so native pending states cannot remain indefinitely.
- Added a recognition-session watchdog derived from configured sample and
  retry budgets, preventing stopped PCM collection from waiting forever.
- Manual playback cancellation now completes the UI callback with an error.

## 2026-07-26 — Automatic radio recognition and metadata overlay

- Fixed asynchronous delivery of the synthetic `playlist newsong` refresh
  being mistaken for a real source change and immediately clearing the overlay.
  A short per-player publication window now covers LMS's deferred notification
  fan-out without affecting playback.
- Fixed native `newmetadata` events clearing a successful automatic overlay.
  Metadata transitions still cancel the active automatic trial and clear PCM,
  but the last recognized overlay remains authoritative until another match,
  playback stop, source change, or automatic-overlay disablement.
- Fixed ignored stations repeatedly scheduling automatic eligibility timers
  which could cancel a manual recognition. Automatic cancellation is now
  trigger-method scoped, ignored stations schedule no automatic timer, and
  genuine stop/source changes explicitly cancel either session type.
- The first match of each automatic cycle is compared with that player's last
  completed automatic match. An identical result ends the sequence
  immediately, skips remaining confirmation/retry requests, and enters the
  normal cooldown. Manual recognition is unchanged.
- Automatic overlay publication now emits both `newmetadata` and a synthetic
  `playlist newsong` notification so Material Skin and Jive refresh their
  now-playing views immediately. The synthetic event is marked internally and
  cannot invalidate capture, cancel a recognition, or affect playback.
- Added default-off automatic recognition for LMS Radio and `hlspl` sources.
  Timers, recognition sessions, workers, retry sequences, and cooldowns are
  independent per physical player; plugin sources such as Spotty fail closed.
- Added a comma-separated, case-insensitive exact station-name ignore list and
  a 30–900 second post-cycle cooldown.
- Added an optional automatic-only metadata and artwork overlay. Overlay
  refreshes are generation-bound and cannot recursively trigger recognition
  cancellation or the existing same-stream metadata PCM clear.
- Native metadata changes cancel an active automatic trial and clear PCM so the
  next trial uses fresh audio. Stop and source changes cancel timers, workers,
  queued retries, and overlays for only the affected player.
- Replaced **Recognize Song** with a non-actionable **Auto Recognition is on**
  row while automatic mode owns the selected radio stream. Manual CLI starts
  are rejected under the same condition.
- Added additive `trigger_method` history migration and **Auto Sample** /
  **Manual Sample** display. Existing rows migrate to manual.

## 2026-07-26 — Consecutive recognition confirmation

- Added a global consecutive-confirmations setting from 1–11, defaulting to 1
  so existing one-match behavior is unchanged.
- Values above 1 require the same Shazam result on consecutive attempts before
  it is shown or written to history. Different matches restart the streak and
  no-matches clear it.
- Confirmation attempts share the configured retry count, sample length, and
  delay. An unconfirmed candidate becomes a no-match when the retry budget or
  available fresh audio is exhausted.

## 2026-07-26 — Source-agnostic same-stream metadata clearing

- Replaced the source-specific Radio and SpotOn settings with one default-off
  **Clear recognition audio when metadata changes on the same stream** setting.
- The setting applies to any current or future source. A non-empty metadata
  change immediately pauses PCM collection while the capture stream identity
  remains unchanged. After it is stable for two seconds, the ring restarts from
  zero without restarting FFmpeg and recognition waits for a fully fresh
  configured sample.
- Recognition snapshots taken before the transition are made stale immediately;
  buffered UI requests during the transition wait instead of analyzing the
  previous song, transition silence, or partially collected new audio.
- Same-stream `playlist newsong` events retain the metadata baseline so plugins
  such as SpotOn cannot bypass change detection by emitting a delayed event.
- Normal LMS `playlist newsong` events continue to invalidate the full capture
  and decoder state for genuinely new songs or stations regardless of these
  metadata settings.

## 2026-07-26 — Optional recognition WAV retention

- Added a default-off global debug setting that retains the exact normalized
  WAV submitted to Shazam under `var/dumps`.
- Debug files use the returned title, or `NoResult`, followed by local date and
  time. Collisions receive a numeric suffix and files require manual deletion.

## 2026-07-26 — Buffered and fresh manual identification

- Buffered mode now waits asynchronously when less than the configured initial
  sample is available instead of returning a decoder-warmup error. Both modes
  therefore use the configured initial duration as the same readiness
  threshold; only Fresh mode clears PCM first.
- Added a global manual-identification dropdown with default **Buffered
  sample** and optional **Fresh sample** behavior.
- Both the LMS CLI and UI use the same recognition entry point and reject
  concurrent requests before any PCM is cleared.
- Fresh mode leaves FFmpeg and continuous PCM capture running, clears only the
  PCM ring when a request is accepted, waits for the configured initial sample
  duration, and then starts Shazam.
- PCM continues filling during recognition and retry delays. Fresh-mode retries
  wait until the configured retry sample length exists and use the newest
  samples.
- Existing playback invalidation and optional same-stream metadata clearing remain
  authoritative. A metadata clear while collecting restarts the fresh sample
  window; a playback generation change cancels it as stale.

## 2026-07-26 — Playback lifecycle and Radio metadata boundaries

- Capture state and the persistent decoder are invalidated on playback stop
  and when LMS reports a genuinely new song or station.
- A delayed `playlist newsong` event does not destroy a decoder that the byte
  hook has already attached to the same new stream.
- Added the default-off global **Clear recognition audio when Radio metadata
  changes** setting.
- When enabled, a changed metadata value must remain stable for two seconds
  before only the PCM ring is cleared. Empty and unchanged values are ignored.
- Metadata clearing is restricted to the existing technical source classifier
  returning exactly `Radio`; SpotOn and every other source are excluded.
- PCM epochs make recognition results stale if their snapshot predates a
  metadata clear or manual reset, without restarting FFmpeg.

## 2026-07-26 — Settings page scaffolding

- Added native LMS global plugin and per-player settings pages.
- Added the default-on global `showSpotifyInHistory` preference. Disabling it
  suppresses both Spotify links and the missing-link message in history detail
  pages while leaving recognition and database storage unchanged.
- The per-player page remains an informational placeholder.

## 2026-07-26 — Configurable recognition and no-match retries

- Added global settings for initial sample length (5–30 seconds), no-match
  retries (0–10), retry sample length (5–30 seconds), and retry delay
  (1–30 seconds).
- Rendered numeric settings with LMS/MUI-native enhanced sliders using
  `stdedit sliderInput_MIN_MAX_STEP`; raw `type="number"` controls do not match
  the surrounding settings UI.
- Each attempt uses the newest configured slice of the fixed 30-second PCM
  ring and passes the same duration to Shazamio's signature generator.
- No-match retries wait asynchronously for new PCM. Worker errors, stream
  changes, and cleared PCM are not retried.
- Final results report `attempts` and `retried`; history and UI completion are
  deferred until all retries finish.

## 2026-07-26 — Permanent recognition history

- Added an append-only SQLite recognition ledger at `var/history.sqlite3`.
- Store successful matches with player, radio source, local/UTC time, song
  metadata, Apple Music, Spotify, and Shazam links, and remote artwork URLs.
- No-match and failed attempts remain log-only.
- Suppress consecutive identical matches on the same player within ten
  minutes while retaining later occurrences.
- Added paginated `shazamcapture history` CLI retrieval and history counts to
  plugin status.
- Added a browsable **Shazam History** app with song rows, remote artwork, and
  complete detail pages.
- Strip query strings and fragments from Apple Music URLs before storage and
  migrate previously stored URLs to the same tracking-free canonical form.
- Make Apple Music, Spotify, and Shazam detail rows clickable external links in
  Material Skin using LMS's standard `weblink` field.
- Canonicalize Apple Music `intent://`, `itmss://`, and plain HTTP links to
  HTTPS, including migration of both indexed URLs and stored normalized JSON.
- Capture the original playback protocol handler's localized plugin name as
  `technical_source` (for example HLSPL Radio, SpotOn Connect, or Radio
  Paradise), with generic core HTTP streams labeled Radio.
- Store Spotify links returned by Shazam, canonicalize Spotify web, intent, and
  app URIs to tracking-free `https://open.spotify.com/track/...` URLs, and make
  them clickable in the history detail page.
- Label missing Spotify results **No Spotify Link Returned** and use LMS's
  default cover image for history rows without remote artwork.

## 2026-07-26 — Persistent PCM capture

- Added one generation-bound FFmpeg decoder per active proxied player.
- The playback hook only performs bounded memory appends and schedules work.
- LMS timers feed encoded bytes through nonblocking pipes; backlogged decoder
  input is discarded rather than delaying playback.
- Added a bounded 30-second mono 16 kHz signed-16-bit PCM ring.
- Recognition now snapshots the newest 20 seconds of PCM instead of joining
  discontinuous compressed-container fragments.
- Added PCM duration, decoder status, and dropped-input counters to `status`.
- The Python helper accepts `.s16le` input and produces the Shazam WAV without
  probing the original stream container.

## 2026-07-26 — Initialization-prefix retention

- Added an immutable 64 KiB initialization prefix per player stream
  generation.
- Snapshots remain capped at 4 MiB. Before rollover they remain contiguous;
  after rollover they contain the retained prefix plus the newest payload that
  fits within the cap.
- This addresses the observed pattern where HLS AAC transcoded by LMS to FLAC
  recognized successfully shortly after stream start, then became undecodable
  after the rolling buffer discarded the FLAC stream header.
- Added `initialization_bytes` to the status response.
- Reset clears the rolling sample counters but deliberately retains the current
  generation's initialization prefix so container-based streams remain
  decodable without restarting playback.

## 2026-07-26 — Milestone-1 proof of concept

### Added

- LMS 9.1.0 plugin manifest and namespaced runtime modules.
- Defensive runtime hook on `Slim::Player::Client::nextChunk`.
- Per-player, per-generation bounded 4 MiB encoded-audio buffers.
- Fail-closed proxied/direct/unknown playback-mode detection.
- LMS CLI `status`, `reset`, `dump`, and `recognize` commands.
- Asynchronous external Python worker with plugin-local snapshots and cleanup.
- FFmpeg normalization and `shazamio` recognition helper.
- Plugin-local Python 3.12 environment, Shazamio, and `imageio-ffmpeg`.
- Successful live SpotOn/Ogg recognition of “Juicy” by Emmett Kai.
- **Recognize Song** entry in the selected track/player's **More** menu.
- Fresh per-entry UI recognition sessions with progress, match rows, no-match,
  and failure states; previous recognition results are never reused.
- Replaced the polling submenu with one-click recognition and asynchronous
  popups: Jive `popupplay` plus Material Skin's native notification channel.
- Changed the context-menu entry from a browsable callback to a direct LMS
  action, preventing Material UI from opening an intermediate progress menu.
- Removed `nextWindow` from the direct action so Material stays on the current
  page and does not synthesize a misleading **Recognize Song** toast.
- Send Material notifications directly with its documented seconds-based
  timeout instead of gating them on PluginManager's internal module key.
- Use a terminal `parentNoRefresh` action for both clients. Material receives
  **Listening** in the action response, while asynchronous
  result/error messages continue through its native notification channel.
- Mark the terminal entry as an actionable `itemplay` text row, preventing
  Material from pre-pushing a browse layer while retaining Jive behavior.
- Replace `itemplay` with plugin-specific `item_shazamcapture`: Material
  deliberately removes `itemplay` rows from More menus as duplicate controls.
- Route progress and completion messages through Material Skin's supported
  `send-notif` command instead of publishing directly to its internal topic.
- Flatten multi-line recognition metadata to **Title — Artist — Album** for
  Material's single-line snackbar while preserving Jive's multi-line popup.

### UI integration failure history

The following attempts were tested and rejected. Preserve this history because
Jive and Material often accept the same LMS menu structure but behave
differently after it is selected.

#### Feed callback with a progress submenu

Initial implementation returned a `url` callback from the TrackInfo provider.
Entering **Recognize Song** started recognition and showed
**Listening** as a submenu row.

Failure: LMS did not push completion into the open menu. Exiting and re-entering
started a new recognition, so the completed result was never visible.

#### “See Results” polling row

A stable per-player UI session and **See Results** row refreshed the existing
recognition without restarting it.

Failure: functionally correct but clunky, required repeated user input, and was
not equivalent to asynchronous completion.

#### Popup completion through Jive only

`$client->showBriefly` with a Jive `popupplay` payload successfully delivered
progress and completion on Jive.

Failure: Material does not consume this path as its native snackbar mechanism.
Material needs its `material-skin send-notif` command.

#### Direct link action

The menu item was changed from a callback to a direct
`shazamcaptureui recognize` command.

Failure: `type => 'link'` made Material pre-push an empty browse layer. The
server command being terminal did not prevent client-side pre-navigation.

#### `nextWindow => 'parent'`

This closed or refreshed the context menu.

Failure: Material navigated away—sometimes to Home—and synthesized a popup
whose text was the menu label **Recognize Song**, not recognition status.

#### No `nextWindow`

Removing navigation metadata stopped Material's explicit Home navigation.

Failure: Jive treated the command response as a browsable result and opened an
empty page.

#### Plain actionable text

Changing the item to `type => 'text'` prevented Material link navigation.

Failure: without a recognized actionable style, the entry could render but not
respond to clicks in Material.

#### `itemplay` style

Adding `style => 'itemplay'` made the text row actionable.

Failure: Material's More-menu parser deliberately removes `itemplay`,
`item_add`, and `item_insert` text rows as duplicate built-in controls, so the
entry disappeared in Material while remaining visible in Jive.

#### Direct internal Material notification publication

The plugin initially called `notifyFromArray` for Material's internal
notification topic and gated it on an assumed PluginManager module key.

Failure: delivery was unreliable and completion did not appear. Timeout units
were also initially supplied as milliseconds, while Material expects seconds.

Fix: call the supported `material-skin send-notif` command, target the selected
player ID, and pass seconds.

#### Multi-line Material match

The result used the same title/artist/album line array as Jive.

Failure: Material's snackbar displayed only the first line.

Fix: keep the Jive array and flatten Material to
`Title — Artist — Album`.

### Final working UI contract

- TrackInfo provider item: plain text with no custom type or style.
- Direct action: `shazamcaptureui items`.
- Terminal behavior: `nextWindow => 'parentNoRefresh'`.
- Pending behavior: Material's native `fetchingItem` three-dot loader.
- Jive: `showBriefly` with `popupplay`.
- Material: one terminal text row on the initiating JSON-RPC response.
- Completion: match, explicit no-match, or concise error.
- Every click starts a fresh recognition; no old result is shown on entry.

### Failure: incorrect Perl module placement

Symptom:

```text
Can't locate Plugins/ShazamCapture/Plugin.pm in @INC
Slim::Utils::PluginManager::load: Couldn't load Plugins::ShazamCapture::Plugin
```

Cause: runtime modules had been moved to the project root. LMS adds the
project's `lib` directory to `@INC` and resolves the manifest module through
the Perl namespace.

Fix: restore modules under `lib/Plugins/ShazamCapture/`, while retaining
`install.xml` at the project root.

### Failure: Python 3.14 native module crash

`shazamio-core` built under Homebrew Python 3.14 but crashed with exit code 139
during `from shazamio import Shazam`. Python 3.14 also lacks the historical
`audioop` module used by `pydub`.

Fix: rebuild the project-local virtual environment with the installed Python
3.12. Do not switch the plugin environment to Python 3.14 until imports and a
real recognition test succeed.

### Failure: LMS tied output handles in forked worker

Symptom:

```text
Can't locate object method "OPEN" via package "Slim::Utils::Log::Trapper"
Worker timed out
```

Cause: the child inherited LMS-tied `STDOUT` and `STDERR`; reopening those
handles invoked the logging trap's unsupported `OPEN` method.

Fix: in the forked child only, `untie` inherited output handles before using
`CORE::open` to redirect worker JSON and diagnostics. This change requires an
LMS restart when modified.

### Historical format limitation — resolved by persistent PCM

The encoded ring stores the newest 4 MiB. Ogg and other containers can require
beginning-of-stream or initialization headers. Once the ring rolls past those
headers, a midstream snapshot may fail to decode.

The interim workaround was to restart an Ogg stream and recognize before the
encoded buffer reached 4 MiB. The current architecture resolves this for
recognition by feeding copied bytes to a nonblocking per-player decoder and
recognizing from a bounded normalized PCM ring. The encoded ring remains only
diagnostic input and is no longer the recognition snapshot.

### Unrelated log noise

The development LMS log contains ShairTunes/CryptX and SpotOn errors unrelated
to this plugin. Attribute failures by package name and surrounding timestamp;
do not modify those plugins.
