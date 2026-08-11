# Terminal test procedures

## Long-stream automatic overlay removal

With automatic recognition and **Remove overlay after no match** enabled, let a
recognized song transition into talk or other content that returns no match.
After the final automatic no-match, verify the recognized title and plugin
artwork disappear and the station's native title/artwork can show again. This
must also work after LMS has refreshed its internal song object during the same
continuous stream and when LMS reports the plugin artwork through an
`/imageproxy/...%2Fplugins%2FShazamCapture%2Fartwork...` URL.

## Plugin API contract

Run the isolated API contract test without playback or network access:

```bash
perl -Ilib t/api.t
```

It verifies required arguments, generated request IDs, physical-player
resolution, use of the manual recognition path, provenance sanitization,
opaque context delivery, terminal callback metadata, and propagation of the
automatic-recognition rejection.

## Boundaries

These procedures use terminal access only. An agent may inspect logs, issue
read-only plugin CLI commands, run self-tests, and restart LMS through an
existing terminal mechanism.

If a test requires selecting a song/station, enabling proxy mode, operating an
LMS UI, or otherwise controlling playback, stop and ask the user to perform
that step. Never automate playback controls.

## Manual settings pages

After LMS loads the changed plugin, ask the user to verify both pages in the
web UI:

1. Open the server-wide plugin settings and select **Shazam Capture**.
2. Confirm **Manual identification sample** defaults to **Buffered sample**.
3. Confirm the recognition controls default to a 10-second initial sample, one
   retry, one consecutive confirmation, a 10-second retry sample, and a
   5-second retry delay.
4. Confirm **Remove recognition overlay after an automatic no-match sequence**
   is off by default. Enable automatic recognition, its metadata overlay, and
   this option; after all configured attempts return no match, confirm the
   original station metadata returns. Confirm the next successful automatic
   sequence publishes its recognized metadata again.
5. Confirm an exhausted no-match, a stopped retry sequence, and a worker or
   recognition failure each clear the overlay. Enable **Accept the first match
   after two no-results** and repeat an unsuccessful sequence; confirm it still
   clears the overlay. Confirm a stale result does not clear it.
6. Restart LMS while a generated automatic overlay is visible. After the first
   post-restart match and subsequent no-match, confirm the plugin restores the
   station title rather than the recognized metadata that survived the restart,
   and confirm the generated artwork is no longer returned by player status.
7. Confirm all five numeric controls render as LMS/MUI-style sliders rather
   than browser-native number boxes.
8. Save boundary values and confirm they persist: sample lengths 5–30 seconds,
   retries 0–10, consecutive confirmations 1–11, and delay 1–30 seconds.
9. Confirm **Accept the first match after two no-results** is available and
   defaults to off. Enable it with at least two retries and a confirmation
   value above 1; after two initial no-matches, confirm the next match succeeds
   without another confirmation attempt.
9. Confirm **Show Spotify information in Shazam History** is available and is
   enabled by default.
10. Disable it, save, and confirm history detail pages contain no Spotify link
   and no **No Spotify Link Returned** row.
11. Confirm existing `spotify_url` database values are unchanged, then enable
   the setting again and confirm the Spotify row returns.
12. Open settings for a selected physical player and select **Shazam Capture**.
13. Confirm **Use current history database**, **View another history
    database**, **Show only this player's history**, **Filter history by**,
    **Filter value**, and **Sort order** are present.
14. Confirm **Use current history database** defaults on and disables the
    database-path field, whose initial displayed value is the absolute
    plugin-local `var/backups` directory.
15. Confirm the database-path field has LMS's native file-selection button.
    Open it and verify the dialog starts in the plugin's `var/backups`
    directory and displays folders plus `.sqlite3` files, but not unrelated
    file types.
16. Select a backup and save. Confirm the picker displays its absolute server
    path, the saved preference is normalized to the corresponding
    plugin-relative path, and reopening settings expands from that file.
17. Alternatively enter a plugin-relative backup such as
    `var/backups/history-YYYYMMDD-HHMMSS.sqlite3`, save, and confirm Shazam
    History shows that file's rows and prefixes its summary with the backup
    path.
18. Confirm the player-only scope, every text filter, and every sort option
    still apply to the backup view.
19. Re-enable **Use current history database**, save, and confirm the path
    remains present but disabled, current history returns, and the backup path
    disappears from the summary.
20. Confirm new manual and automatic matches appear in the active database but
    do not change the selected backup's size, modification time, or row count.
21. Confirm absolute paths outside the plugin, `..` traversal, missing files, directories,
    incompatible databases, and symlinks resolving outside the plugin produce
    a concise history error without changing the active database.
22. Confirm **No filter** disables the value field, while choosing Station,
    Stream source, Artist, Song title, Album, Capture type, API caller, or API
    reason enables it. Confirm API filters find matching API-triggered records
    and safely show no matches for older backups without API columns.
23. Save a Station filter such as `The Wave` with **Newest to Oldest** and
    confirm those values remain selected for that player only.
24. Open **My Apps → Shazam History** and confirm the summary reads like
    `All players - Station contains "The Wave" - Newest to Oldest`.
25. Enable the player-only checkbox and confirm the summary uses the selected
    player's display name instead of **All players**, and that both the player
    scope and text filter apply together.
26. Confirm an empty filter value shows all records in the selected player
    scope, and verify each chronological and alphabetical sort option.

To compare manual sample modes with the same UI or CLI recognition action:

1. With **Buffered sample**, wait until PCM is populated and trigger
   recognition. Confirm the worker starts immediately.
2. Clear PCM or change tracks, then trigger Buffered recognition before the
   configured initial duration exists. Confirm the request is accepted and the
   worker waits for the full duration instead of returning a warmup error.
3. Select **Fresh sample**, set the initial sample to 5 seconds, and trigger
   recognition. Confirm the CLI/UI accepts immediately, `pcm_seconds` resets,
   and the worker starts only after approximately five seconds.
4. Trigger again while collection or recognition is active. Confirm it is
   rejected and the active sample is not cleared.
5. Configure a longer retry sample than the initial sample. After a no-match,
   confirm PCM continues growing and the retry uses the newest configured
   duration once it is available.
6. With same-stream metadata clearing enabled, cause a metadata change during fresh
   collection. Confirm transient metadata does not cancel the request, but a
   value that remains stable for two seconds completes it with **Song changed
   before recognition completed**. FFmpeg must remain running.

The same-stream metadata option is disabled by default. To test it manually:

1. Enable **Clear recognition audio when metadata changes on the same stream**
   and save.
2. Play Radio, SpotOn, or another source that reuses one underlying stream.
3. After a non-empty metadata change remains stable for two seconds, confirm
   `pcm_transition` is first `1` with `pcm_seconds` at zero, then returns to
   `0` and PCM begins growing while `decoder_running` remains true.
4. Confirm repeated identical or empty metadata does not clear the ring.
5. Confirm a same-stream `playlist newsong` event does not reset the metadata
   baseline or prevent the clear.
6. Confirm the behavior is source-agnostic rather than based on the technical
   source label.
7. Stop playback or select a genuinely new song/station and confirm the old capture is
   invalidated; after a new stream starts, it has a fresh buffer/decoder state.
8. Trigger recognition before a metadata transition. Confirm the UI reports
   progress immediately, then a stable metadata change completes the request
   with **Song changed before recognition completed** rather than carrying the
   request into the following song. Confirm the same error is returned for a
   `playlist newsong` boundary and FFmpeg remains running for a same-stream
   transition.

UI inspection is manual; automated tests must not navigate the browser.

## Manual UI recognition

1. Select a physical player playing a proxied radio stream.
2. Open the current track/player **More** menu.
3. Select **Recognize Song**.
4. Confirm Jive remains on the current menu with an inline wheel until
   recognition finishes, then opens a child result window. Confirm Material
   does not open that child window; SB2 may enter its native callback level.
5. Confirm the result reports title, artist, and album, or **No song
   found** / **Identification failed**.
6. Confirm the behavior in Jive, Material, and SB2.
7. In Jive, use Back to return from the result child. Select **Recognize Song**
   again and confirm a new recognition starts.
8. Interrupt capture or change playback during a manual request and confirm
   progress is replaced by an error rather than remaining indefinitely.

Client-specific acceptance criteria:

- Jive replaces the **Recognize Song** row arrow with its inline wheel while
  the request is pending, removes the wheel on every terminal path, and opens
  one child window containing the terminal result and a working Back action.
- Material remains on the current page and shows its three-dot loader while
  recognition is pending; it must not open Jive's child result window.
- The Material entry must be visible and clickable.
- The Material terminal snackbar must contain only plain recognition text; it
  must not expose `<div>`, `style`, or other HTML decoration.
- Material match popup contains all three fields as
  `Title — Artist — Album`.
- SB2 shows its block animation while waiting, then artist on the small top
  line and title on the large bottom line.
- After opening the SB2 row, the log must not show
  `UI recognize command origin=jive source=<none> connection=<none>`. A fresh
  row must use the URL callback and therefore receive `isButton`.
- Triggering from SB2 must not create Jive or Material notifications;
  triggering from Jive must not create a Material notification, and vice versa.

After the SB2 result appears, verify that the blank-screen regression did not
occur:

```bash
tail -n 1000 "/Users/dexi/Library/Logs/Squeezebox/server.log" | \
  rg -n -C 3 \
  "origin=jive source=<none>|undefined value as an ARRAY reference.*XMLBrowser"
```

Expected: no matches for the tested request. This signature means SB2 was
given a direct control-UI action or the cached-row fallback omitted `items`.

## UI structure verification

Inspect the exact JSON consumed by Material without clicking or changing
playback:

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"id":1,"method":"slim.request","params":["PLAYER_ID",["trackinfo","items","0","200","playlist_index:0","menu:nowhere","useContextMenu:1"]]}' \
  http://localhost:9000/jsonrpc.js \
  | jq '.result.item_loop[] | select(.text=="Recognize Song")'
```

Expected shape:

```json
{
  "text": "Recognize Song",
  "actions": {
    "go": {
      "cmd": ["shazamcaptureui", "items"],
      "params": {
        "origin": "material"
      },
      "nextWindow": "parentNoRefresh"
    }
  }
}
```

The request-context wrapper makes the menu request's transport authoritative
while constructing the action: JSON-RPC is Material and SqueezePlay/Comet is
Jive. Material's action must use `parentNoRefresh`; Jive's action must omit
`nextWindow`, and Jive's row must also omit its top-level `nextWindow`.
Traditional-button rows retain top-level `nextWindow=parent`. The direct
command verifies the transport again and remains pending until recognition
completes, keeping each UI's native loader visible. Material contains one text
row. A successful Jive match contains three rows in title, artist, album order;
errors and no-matches contain one. Do not add a custom type; Jive's terminal
rows use the standard `itemNoAction` style so they cannot be selected.

Traditional-button rows must not contain `actions`, `jive.actions`, or
`itemActions`; those fields make SB2 bypass the callback URL. If a cached SB2
row nevertheless reaches the direct command with `origin=auto` and no source,
the response must contain an `items` array before the native result display is
scheduled.

Jive's terminal response must be a complete paged chunk with `offset=0`, an
accurate `count`, and inert `item_loop` rows. Without `offset`, SqueezePlay
treats the requested chunk as unsatisfied and repeats the recognition action
instead of settling the child window.

After restart, confirm the request-context wrapper was installed:

```bash
rg -n "installed (request-context|result-row transport) wrapper" \
  "/Users/dexi/Library/Logs/Squeezebox/server.log" | tail -1
```

For an actual Jive More-menu fetch, the log must show a serialized row whose
source contains `SqueezePlay` and whose `nextWindow` is `<child>`. Material's
serialized row must show `origin=material` and
`nextWindow=parentNoRefresh`.

SqueezePlay may also rebuild TrackInfo using an internal source-less request
with `menu=track`. That row must log `origin=auto` and
`nextWindow=<child>`; never infer Material from the named menu mode alone.

## History database management

On the global **Shazam Capture** settings page:

1. Select **New database…**, enter `settings-test.sqlite3`, and choose
   **Use database**. Confirm it becomes active and appears in the selector.
2. Choose **Create backup**. Confirm the status names one standalone
   `var/backups/settings-test-*.sqlite3` file with no matching `-wal` or
   `-shm` file.
3. Add or recognize a history entry, select the clear confirmation, and choose
   **Back up and clear database**. Confirm Shazam History is empty and another
   verified backup was reported.
4. Switch back to `history.sqlite3`. Confirm its previous history is unchanged.
5. Attempt a new name containing `/` or `..`. Confirm the operation is rejected
   and the previously active database remains selected.

Preserve the generated database and backup evidence unless the user explicitly
requests its removal.

## Dependency checks

From the project root:

```bash
python/venv/bin/python -m pip check
python/venv/bin/python -c \
  'from shazamio import Shazam; import imageio_ffmpeg; print("imports=ok"); print(imageio_ffmpeg.get_ffmpeg_exe())'
xmllint --noout install.xml
```

Expected: no broken requirements, successful Shazam import, an FFmpeg path
inside `python/venv`, and no XML error.

To rebuild dependencies, use a compatible Python 3.12 interpreter and remain
inside this project:

```bash
python3.12 -m venv python/venv
python/venv/bin/python -m pip install -r python/requirements.txt
```

Do not install globally. On a host where Python 3.12 has a nonstandard command
name, use that absolute interpreter path only for the `-m venv` command.

After LMS starts, `shazamcapture status` must report a `runtime` object whose
`python_ready` and `ffmpeg_ready` values are `1`. The normal development
installation should report `python_source:plugin` and
`ffmpeg_source:plugin`.

To test explicit override validation without changing LMS preferences, start a
separate test process with `SHAZAMCAPTURE_PYTHON` or
`SHAZAMCAPTURE_FFMPEG` set. A valid executable must report
`source:environment`; a missing or non-executable override must report
`ready:0` with a concise error and must not fall back silently.

## LMS startup verification

After an LMS restart, inspect:

```bash
rg -n -i -C 5 \
  "Shazam Capture|nextChunk hook|Couldn't load Plugins::ShazamCapture|hook unavailable" \
  "/Users/dexi/Library/Logs/Squeezebox/server.log"
```

Expected:

```text
installed Slim::Player::Client::nextChunk hook
Shazam Capture initialized on LMS 9.1.0
```

Also confirm that the restarted process is genuinely new:

```bash
ps -o pid,lstart,command -ax | rg '[s]limserver'
lsof -nP -iTCP -sTCP:LISTEN | rg ':(9000|9090)'
```

The bundled `restart-server.sh` uses relative paths and can stop LMS without
restarting it if run from the wrong directory. A foreground launch can also
fail with “Address already in use” while an older supervised process continues
serving stale plugin code. Treat the active PID start time and post-restart
menu JSON—not the restart command's exit code—as authoritative.

## Interactive CLI

Connect:

```bash
nc localhost 9090
```

Use the current test player:

```text
00:04:20:1f:78:65 shazamcapture status
00:04:20:1f:78:65 shazamcapture reset
00:04:20:1f:78:65 shazamcapture recognize
00:04:20:1f:78:65 shazamcapture recognizefresh
00:04:20:1f:78:65 shazamcapture overlay
00:04:20:1f:78:65 shazamcapture history limit:25 offset:0
00:04:20:1f:78:65 shazamcapture dump
```

After a successful recognition, open **My Apps → Shazam History**. Confirm the
newest row shows the song title and either its remote artwork or LMS's default
cover. Open it and confirm the artist, album, radio station, player, local
recognition time, technical playback source, and Apple Music, Spotify, and
Shazam fields are present when available. External URL rows must be clickable
in Material Skin.

Spotify URLs must use the clean
`https://open.spotify.com/track/...` form without query strings or fragments.
When Shazam returns no Spotify URL, confirm the detail page instead shows
**Spotify: No Spotify Link Returned**. Existing database rows created before
Spotify capture was added are expected to use this fallback.

Repeat recognition immediately without changing the playing song. The popup
may report the match again, but `history_entries` and the app row count must not
increase. A no-match or failed recognition must likewise leave history
unchanged.

LMS CLI URL-encodes its response. Examples:

- `%3A` is `:`
- `%2F` is `/`
- `%22` is `"`
- `%7B` and `%7D` are `{` and `}`
- `%20` is a space

The `last_result` field is URL-encoded JSON and should be decoded, then parsed
as JSON.

## Proxied stream capture

Ask the user to select a remote stream already configured for proxied playback.
Do not change proxy settings or start playback yourself.

After 10–20 seconds:

```text
00:04:20:1f:78:65 shazamcapture status
```

Expected:

```text
playback_mode:proxied
capturing:1
hook_installed:1
bytes_buffered:<positive and increasing>
total_bytes_seen:<positive and increasing>
pcm_bytes_buffered:<positive and increasing>
pcm_seconds:<increasing toward 30>
decoder_status:running
```

The encoded diagnostic buffer is capped at `4194304` bytes. The PCM ring is
capped at 960000 bytes (30 seconds). `decoder_input_dropped` should normally
remain zero; any increase must not interrupt playback.

## Recognition

Wait until `pcm_seconds` is at least 5 before the first recognition. Repeat
after the encoded buffer has rolled over. Both requests should use current PCM
and remain independent of FLAC/Ogg container initialization.

Start:

```text
00:04:20:1f:78:65 shazamcapture recognize
```

Expected immediate response:

```text
ok:1 started:1 generation:<n>
```

Poll:

```text
00:04:20:1f:78:65 shazamcapture status
```

Expected transition: `worker_running:1` to `worker_running:0`. A successful
`last_result` contains:

```json
{
  "ok": true,
  "matched": true,
  "stale": false,
  "track": {
    "title": "...",
    "artist": "...",
    "album": "...",
    "shazam_key": "..."
  }
}
```

`stale:true` means the stream generation changed while recognition ran.

## Reset

```text
00:04:20:1f:78:65 shazamcapture reset
```

Expected: `ok:1`. The next status should briefly show an empty/small buffer,
then growth resumes without a pause or audible interruption.

## Direct and unknown playback

Ask the user to start a direct-streamed remote source. Do not change the
streaming preference yourself. Wait at least 15 seconds, then inspect status
and request recognition.

Expected:

```text
playback_mode:direct
capturing:0
ok:0
stage:capture
error:The current stream is using direct playback...
```

An ambiguous transition must return `playback_mode:unknown` and reject capture.

## Dump safety

Encoded dumps are disabled by default:

```text
00:04:20:1f:78:65 shazamcapture dump
```

Expected: an explicit “Encoded dumps are disabled” error and no external file.

## Playback-safety evidence

During every test, ask the user to confirm that playback did not pause, restart,
skip, rebuffer unexpectedly, change volume, change synchronization state, or
audibly glitch. Terminal evidence should also show the player remaining in its
normal playing/streaming state.

Required future matrix:

1. Proxied MP3 radio
2. Proxied AAC radio
3. Proxied plugin-provided source
4. Proxied transcoded source
5. Two independent players with different streams
6. Same station on two players with isolated generations
7. Direct stream rejection
8. Unknown topology rejection
9. Local file ignored
10. Stream change and player stop during recognition
11. FFmpeg missing, Shazam no-match, and network failure behavior
