# Terminal test procedures

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
4. Confirm all five numeric controls render as LMS/MUI-style sliders rather
   than browser-native number boxes.
5. Save boundary values and confirm they persist: sample lengths 5–30 seconds,
   retries 0–10, consecutive confirmations 1–11, and delay 1–30 seconds.
6. Confirm **Accept the first match after two no-results** is available and
   defaults to off. Enable it with at least two retries and a confirmation
   value above 1; after two initial no-matches, confirm the next match succeeds
   without another confirmation attempt.
7. Confirm **Show Spotify information in Shazam History** is available and is
   enabled by default.
8. Disable it, save, and confirm history detail pages contain no Spotify link
   and no **No Spotify Link Returned** row.
9. Confirm existing `spotify_url` database values are unchanged, then enable
   the setting again and confirm the Spotify row returns.
10. Open settings for a selected physical player and select **Shazam Capture**.
11. Confirm the page says that no configurable player settings are available.

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
   collection. Confirm PCM clears and the initial wait restarts without FFmpeg
   stopping.

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
8. Trigger recognition during the two-second transition. Confirm the UI reports
   progress immediately, no worker starts until the transition ends and the
   configured fresh duration has accumulated, and the retained WAV contains
   only post-transition PCM.

UI inspection is manual; automated tests must not navigate the browser.

## Manual UI recognition

1. Select a physical player playing a proxied radio stream.
2. Open the current track/player **More** menu.
3. Select **Recognize Song**.
4. Confirm Jive and Material do not open a result page; SB2 may enter its
   native callback level. Confirm the native loading animation remains until
   recognition finishes.
5. Confirm the result reports title, artist, and album, or **No song
   found** / **Identification failed**.
6. Confirm the behavior in Jive, Material, and SB2.
7. Select **Recognize Song** again and confirm a new recognition starts.
8. Interrupt capture or change playback during a manual request and confirm
   progress is replaced by an error rather than remaining indefinitely.

Client-specific acceptance criteria:

- Jive remains on the current menu; it must not open an empty result page.
- Jive replaces the **Recognize Song** row arrow with its inline wheel while
  the request is pending, removes the wheel on every terminal path, and shows
  the terminal popup only through Jive.
- Material remains on the current page and shows its three-dot loader while
  recognition is pending.
- The Material entry must be visible and clickable.
- The Material terminal snackbar must contain only plain recognition text; it
  must not expose `<div>`, `style`, or other HTML decoration.
- Material match popup contains all three fields as
  `Title — Artist — Album`.
- SB2 shows its block animation while waiting, then artist on the small top
  line and title on the large bottom line.
- Triggering from SB2 must not create Jive or Material notifications;
  triggering from Jive must not create a Material notification, and vice versa.

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

Named modes may carry `origin=material` and numeric `menu=1` carries
`origin=auto`, but the direct command's retained transport is authoritative:
JSON-RPC is Material and SqueezePlay/Comet is Jive. Its request remains pending
until recognition completes, which keeps each UI's native loader visible. The
Material terminal response must contain one text row with the result, and the
control action must use `parentNoRefresh`. Do not add a custom type or item
style.

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

To rebuild dependencies, use Python 3.12 and remain inside this project:

```bash
/opt/homebrew/bin/python3.12 -m venv python/venv
python/venv/bin/python -m pip install -r python/requirements.txt
```

Do not install globally.

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
