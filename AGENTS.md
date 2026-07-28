# Music Detect / Shazam Capture agent handoff

## Purpose

This project is a Lyrion Music Server (LMS) milestone-1 proof of concept. It
passively copies audio bytes that LMS is already proxying to the original
physical player, keeps a bounded per-player buffer, decodes a snapshot with
FFmpeg, submits normalized audio to Python `shazamio`, and exposes the result
through LMS CLI commands.

The plugin must never open the source URL independently, create a hidden player,
join a synchronization group, change proxy preferences, restart playback, or
block LMS's event loop. Playback must remain untouched if capture, decoding, or
recognition fails.

Development information in this file is intentionally specific to the current
Mac. Runtime code must remain host-agnostic and portable: derive plugin paths at
runtime, keep dependencies configurable, and never embed this machine's user
name, player ID, application bundle path, or LMS ports in plugin behavior.

## Modification and operating authority

- Modify or generate files only inside:
  `/Users/dexi/Library/Application Support/Squeezebox/Plugins/Music Detect`
- Read-only inspection outside the project is allowed for LMS source, logs,
  preferences, caches, runtime state, and other plugins.
- Agents may restart LMS using terminal-accessible mechanisms, run self-tests,
  inspect logs, and issue LMS CLI commands.
- Do not modify LMS core, other plugins, LMS preferences, system Python,
  system packages, shell profiles, application bundles, or cache contents.
- Install Python packages only into this project's `python/venv`.
- Do not use `sudo` or install/replace a system FFmpeg.
- UI inspection, browser interaction, playback control, changing streaming
  preferences, or any test requiring actions beyond terminal access must stop
  at a clear instruction for the user. Do not perform those actions for them.
- Do not restart, stop, pause, seek, or otherwise control the selected player's
  playback from plugin code or automated tests.
- Preserve existing user changes and generated recognition evidence.

## Git synchronization policy

- After every project change, commit the completed work and push it to the
  configured private GitHub repository before considering the task finished.
- Never commit generated recognition evidence, captured audio, runtime
  databases, temporary files, caches, credentials, or the project-local Python
  virtual environment.
- If a push cannot be completed, preserve the local change and clearly report
  that the repository is not synchronized.

## Development host

- Workspace/plugin root:
  `/Users/dexi/Library/Application Support/Squeezebox/Plugins/Music Detect`
- LMS: Lyrion Music Server 9.1.0, revision `1771315634`,
  build date 2026-02-19, Perl 5.34
- LMS application server root (read-only):
  `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/Resources/server`
- LMS preferences (read-only):
  `/Users/dexi/Library/Application Support/Squeezebox/server.prefs`
- LMS main log:
  `/Users/dexi/Library/Logs/Squeezebox/server.log`
- LMS scanner log:
  `/Users/dexi/Library/Logs/Squeezebox/scanner.log`
- LMS cache (read-only):
  `/Users/dexi/Library/Caches/Squeezebox`
- HTTP port: `9000`
- CLI port: default `9090` (no explicit `cliport` entry was found)
- Tested physical player: `00:04:20:1f:78:65`
- Homebrew Python 3.12: `/opt/homebrew/bin/python3.12`
- Plugin Python:
  `/Users/dexi/Library/Application Support/Squeezebox/Plugins/Music Detect/python/venv/bin/python`
- Plugin FFmpeg is supplied by `imageio-ffmpeg` inside the virtual environment.

## Required project layout

LMS reads `install.xml` from the project root, adds the project's `lib`
directory to Perl `@INC`, and loads the manifest module from:

```text
Music Detect/
├── AGENTS.md
├── install.xml
├── strings.txt
├── README.md
├── HTML/
│   └── EN/
│       └── plugins/
│           └── ShazamCapture/
│               └── settings/
│                   ├── basic.html
│                   └── player.html
├── lib/
│   └── Plugins/
│       └── ShazamCapture/
│           ├── Plugin.pm
│           ├── Hook.pm
│           ├── Capture.pm
│           ├── Decoder.pm
│           ├── Worker.pm
│           ├── History.pm
│           ├── HistoryUI.pm
│           ├── Settings.pm
│           ├── PlayerSettings.pm
│           └── UI.pm
├── python/
│   ├── recognize.py
│   ├── requirements.txt
│   └── venv/
├── var/
│   ├── tmp/
│   ├── dumps/
│   └── logs/
└── docs/
    ├── TECHNICAL-NOTE.md
    ├── CHANGELOG.md
    └── TESTING.md
```

Do not move the Perl modules to the project root. LMS resolves
`Plugins::ShazamCapture::Plugin` as
`lib/Plugins/ShazamCapture/Plugin.pm`.

## Implemented architecture

- `Plugin.pm`: initializes the dedicated `plugin.shazamcapture` log category,
  installs the hook, registers CLI dispatch, creates plugin-local runtime
  directories, and returns status/results.
- `Hook.pm`: defensively wraps `Slim::Player::Client::nextChunk`.
- `Capture.pm`: holds bounded encoded diagnostic input, decoder queues, and a
  rolling mono 16 kHz PCM ring per physical player and stream generation.
  Local `file://` tracks are ignored.
- `Decoder.pm`: uses LMS timers to feed copied bytes to a persistent per-player
  FFmpeg process through nonblocking pipes and drains normalized PCM. Input is
  discarded rather than delaying playback when the decoder falls behind.
- `Playback.pm`: invalidates capture and decoder state on stop or a genuinely
  new song/station. One optional default-off global preference pauses PCM
  collection immediately when metadata changes while the underlying stream
  identity remains unchanged, then restarts the ring from zero after the
  metadata is stable for two seconds. Empty and unchanged metadata are ignored.
- `Worker.pm`: forks an external Python worker and polls it asynchronously with
  LMS timers. The LMS event loop never waits for FFmpeg or the network.
- `History.pm`: appends successful matches to plugin-local SQLite storage,
  suppresses immediate same-player duplicates, migrates additive columns, and
  canonicalizes stored Apple Music and Spotify URLs.
- `HistoryUI.pm`: exposes **Shazam History** as an LMS app with song rows,
  remote artwork or LMS's default cover, complete metadata, and clickable
  external links. The global `showSpotifyInHistory` preference suppresses only
  the Spotify detail row; capture and database storage remain unchanged.
- `Settings.pm`: registers the global LMS settings page and persists the
  default-on Spotify history display preference plus the default-off
  same-stream metadata PCM-clear preference, recognition sample lengths,
  no-match retry count, retry delay, and buffered/fresh manual sample mode. Fresh mode clears
  only PCM after accepting a request, then waits for the configured sample
  while the shared decoder continues. Numeric settings use LMS enhanced sliders:
  `type="text"` with `stdedit sliderInput_MIN_MAX_STEP`; do not use raw
  `type="number"` controls.
- `PlayerSettings.pm`: registers an intentionally non-configurable per-player
  LMS settings page.
- `UI.pm`: adds **Recognize Song** to `Slim::Menu::TrackInfo` using LMS's
  native asynchronous callback pattern, leaves native loading animations
  visible, and routes terminal results only to the initiating UI path.
- `python/recognize.py`: confines input/output paths to the plugin root,
  converts a PCM snapshot to WAV, invokes `Shazam().recognize()`, and emits one
  normalized JSON object including Apple Music, Spotify, Shazam, and artwork
  URLs when Shazam returns them.

Verified LMS 9.1.0 data path:

```text
active protocol handler / transcoder
  -> Slim::Player::Client::nextChunk($client, $max_bytes, $retry_callback)
  -> Slim::Web::HTTP::sendStreamingResponse($httpClient)
  -> syswrite to the original physical player's stream socket
```

The wrapper calls the original method first, preserves scalar/list/void
context, return values, exceptions, mutable inputs, and side effects, then
copies only a successful scalar-reference result. An observer error is trapped
and must never reach playback.

Observed bytes within five seconds are positive evidence of proxied topology.
An active player with no observations for fifteen seconds is reported as
direct. Ambiguous/transitional topology is `unknown`; direct and unknown modes
fail closed.

## UI interoperability contract

The working UI shape is deliberate. Do not simplify it without testing both
Jive and Material Skin:

- Register **Recognize Song** through `Slim::Menu::TrackInfo`, the current
  track/player **More** menu extension point.
- Return a plain `name`, callback `url`, and `nextWindow => 'parent'` for
  traditional-button clients. Control UIs receive an item-specific
  `shazamcaptureui items` action with a fixed `origin` parameter. The
  list-shaped command makes Material set its native `fetchingItem` state.
- Use `parentNoRefresh` only on Material's `go` action so Material stays on
  the current view. Omit `nextWindow` from both Jive's action and its
  top-level row: SqueezePlay otherwise falls back to the row value and closes
  the More menu. With neither value present, Jive locks the current row with
  its inline wheel and pushes the terminal response as a child window with a
  normal manual Back action. Return the terminal
  message as each direct request's sole text row. Mark Material's response row
  with inert
  `nextWindow => 'parentNoRefresh'` metadata to prevent Material from wrapping
  a sole non-clickable text row in browse-page HTML before sending it to the
  escaped snackbar. Leave the traditional-button row's top-level
  `nextWindow => 'parent'`.
- The callback remains pending until recognition has a terminal result.
  Material displays its native three-dot loader during that wait; Jive
  displays its inline wheel.
- Direct control-UI commands must call `setStatusProcessing` before starting
  recognition and `setStatusDone` only for a terminal result; otherwise LMS
  completes JSON-RPC as soon as the dispatch handler returns.
- Jive's terminal child response must include `offset => 0`, `count => 1`,
  and one inert `item_loop` row. Omitting the offset makes SqueezePlay refetch
  the same action as an unsatisfied page instead of settling the child window.
- Do not send a **Listening** popup. Leave the callback pending so LMS's native
  block animation is visible on SB2 and Material's native loader remains
  visible. SqueezePlay/Jive replaces the selected row's right arrow with its
  native inline wheel while the direct action request remains pending, then
  opens the result child window.
- The callback parameters identify traditional-button requests with
  `isButton`. Material uses both named TrackInfo modes and numeric `menu=1`;
  Jive can also use named modes or numeric `menu=1`. Retain the active
  `Slim::Control::Request` only for the dynamic scope of its common `execute`
  method and use that request's transport while building the row: Material
  uses JSON-RPC and Jive uses SqueezePlay/Comet. This is required because
  SqueezePlay can retain TrackInfo request objects whose handler pointer
  predates plugin initialization. The direct command verifies the retained
  transport again. Do not infer origin inside the later URL
  callback: XMLBrowser re-fetches actions with `menu=trackinfo`, supplies no
  callback query, and TrackInfo uses a global cached feed.
- Because a TrackInfo feed can outlive the request which built it, enforce the
  final recognition-row navigation while XMLBrowser serializes the row for the
  concrete request. Remove action-level and row-level `nextWindow` for
  SqueezePlay/Comet; set action-level `parentNoRefresh` for JSON-RPC.
- SB2 terminal matches use a traditional `line` display with artist on the
  small top line and title on the large bottom line.
- Scope terminal delivery to the initiating path: SB2 receives only a line
  display, Jive receives its child result window, and Material receives its
  terminal list response only on the initiating browser connection.
- The session watchdog guarantees every accepted request eventually completes
  with a match, explicit no-match, or concise error.
- A separate direct-UI watchdog runs five seconds beyond the session deadline
  and completes/cancels a stranded manual action so Jive's inline wheel and
  Material's loader cannot run forever if the normal callback path faults.
- Traditional players use the same `showBriefly` call's `line` payload.
- Material fallback popups use its supported
  `['material-skin', 'send-notif', ...]` command; the direct action returns its
  terminal popup text on the initiating JSON-RPC response.
- Material timeout values are seconds. Jive's payload duration is
  milliseconds; the outer `showBriefly` duration is seconds.
- Jive accepts multiple lines. Material is single-line; format matches as
  `Title - Artist - Album`.
- Target Material notifications with the selected physical player's ID.

Known traps:

- Cancellation and stopped PCM collection must complete the manual callback;
  otherwise the native loading state can remain indefinitely.
- Material removes `itemplay`, `item_add`, and `item_insert` rows from More
  menus as duplicate built-in controls.
- Newline-delimited Material messages show only the first field.
- Re-entering **Recognize Song** starts a fresh recognition; never use menu
  re-entry as result retrieval.

## Logging and diagnostics

Primary live inspection:

```bash
tail -n 500 "/Users/dexi/Library/Logs/Squeezebox/server.log"
```

Focused inspection:

```bash
rg -n -i -C 8 \
  "shazam|shazamcapture|plugin.shazamcapture|recognition result|worker|ffmpeg|observer failed|hook unavailable" \
  "/Users/dexi/Library/Logs/Squeezebox/server.log"
```

Expected startup messages:

```text
installed Slim::Player::Client::nextChunk hook
Shazam Capture initialized on LMS 9.1.0
```

Recognition completion is logged as a redacted JSON summary. Never log raw
audio, cookies, authentication headers, signed query parameters, or complete
service responses. Redact URL query strings.

Runtime artifacts must stay under `var/tmp`, `var/dumps`, and `var/logs`.
Snapshots and worker outputs are normally deleted after completion. Encoded
dumps are disabled by default.

## Useful development tools

Prefer these terminal tools:

- `rg` for source/log searches and `rg --files` for file discovery
- `sed` and `tail` for narrow source/log inspection
- `nc localhost 9090` for interactive LMS CLI testing
- `xmllint --noout install.xml` for manifest syntax
- bundled LMS Perl for targeted syntax checks:
  `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/MacOS/perl`
- `python/venv/bin/python -m pip check` for dependency consistency
- `python/venv/bin/python` for helper/import tests
- `imageio_ffmpeg.get_ffmpeg_exe()` to locate the plugin-local FFmpeg

Standalone Perl compilation can produce misleading LMS bootstrap or
`JSON::XS` ABI errors because the full LMS runtime has not initialized its
custom library paths. Treat the actual LMS startup log as authoritative, while
still running isolated checks where practical.

The bundled restart helper can stop LMS without successfully relaunching it
when invoked from the wrong directory or a restricted process environment.
Resolve the active `slimserver.pl` PID, confirm its start time, and verify ports
9000/9090 after every restart. An older supervised process may still own the
ports, causing a new test process to fail without loading changed code.

## Current verified result

The tested SpotOn stream was positively detected as:

```text
playback_mode: proxied
format: ogg
capturing: 1
hook_installed: 1
```

Captured proxied Ogg audio was decoded and recognized without interrupting
playback:

```json
{
  "ok": true,
  "matched": true,
  "matches": 1,
  "stale": false,
  "track": {
    "title": "Juicy",
    "artist": "Emmett Kai",
    "album": "Midnight - Single",
    "shazam_key": "377560234"
  }
}
```

See `docs/CHANGELOG.md` for fixes and known failures and `docs/TESTING.md` for
copy-ready test procedures.
