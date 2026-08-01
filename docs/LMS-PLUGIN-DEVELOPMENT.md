# LMS plugin development on macOS for Linux deployment

This guide is a handoff for agents developing Lyrion Music Server (LMS)
plugins on the current macOS development machine and deploying them to a
Linux LMS production host. It records machine-specific facts separately from
portable plugin design rules and summarizes behavior verified across classic
Squeezebox, SqueezePlay/Jive, the standard web interface, and Material Skin.

It is intentionally plugin-neutral. Names and examples such as `ExamplePlugin`
are placeholders and must be replaced by the plugin being developed.

## 1. Development-machine inventory

The installed development server is:

- Lyrion Music Server 9.1.0, revision `1771315634`, build date 2026-02-19
- LMS Perl 5.34, supplied inside the application bundle
- HTTP interface on port `9000`
- CLI on the default port `9090`; there is no explicit `cliport` entry in the
  current preferences
- LMS application server source:
  `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/Resources/server`
- Bundled Perl:
  `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/MacOS/perl`
- Restart helper:
  `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/MacOS/restart-server.sh`
- User plugin directory:
  `/Users/dexi/Library/Application Support/Squeezebox/Plugins`
- Preferences:
  `/Users/dexi/Library/Application Support/Squeezebox/server.prefs`
- Main log: `/Users/dexi/Library/Logs/Squeezebox/server.log`
- Scanner log: `/Users/dexi/Library/Logs/Squeezebox/scanner.log`
- Cache: `/Users/dexi/Library/Caches/Squeezebox`

These absolute paths are development facts, not runtime configuration. Never
embed them, the local user name, a player MAC address, or ports in portable
plugin code. Derive the plugin root from `__FILE__`, use LMS APIs for server
configuration, and keep executable paths configurable.

The application bundle source is extremely useful as the authoritative API
reference for this exact LMS build. Read it, but do not edit it. LMS APIs are
mostly documented by their implementations and by bundled plugins, so inspect
both the relevant `Slim::*` module and a working core plugin before copying a
pattern.

## 2. How LMS discovers and loads a plugin

An unpacked development plugin lives as one directory directly below the user
plugin directory. A conventional layout is:

```text
Example Plugin/
├── install.xml
├── strings.txt
├── README.md
├── HTML/
│   └── EN/
│       └── plugins/
│           └── ExamplePlugin/
│               ├── html/
│               │   └── images/
│               └── settings/
│                   ├── basic.html
│                   └── player.html
├── lib/
│   └── Plugins/
│       └── ExamplePlugin/
│           ├── Plugin.pm
│           ├── Settings.pm
│           └── UI.pm
└── var/
```

LMS reads `install.xml` at the plugin root, adds the plugin's `lib` directory
to Perl `@INC`, and loads the manifest's module. Therefore:

```xml
<module>Plugins::ExamplePlugin::Plugin</module>
```

must resolve to:

```text
lib/Plugins/ExamplePlugin/Plugin.pm
```

Do not put the Perl modules at the plugin root. Keep the directory and package
names identical, including case; Linux filesystems are normally
case-sensitive even when the development Mac volume is not.

The manifest should have a unique UUID, localized name and description tokens,
a monotonically increasing version, default enabled state, plugin type, and an
honest LMS compatibility range. Validate it with:

```bash
xmllint --noout install.xml
```

`strings.txt` supplies localization tokens used by the manifest, Perl code,
menus, and settings templates. Treat token names as stable API. Include an
English value and do not hard-code user-visible prose where LMS expects a
string token.

The main module usually inherits from `Slim::Plugin::Base` or a more specific
base such as `Slim::Plugin::OPMLBased`. In `initPlugin`, call the superclass
initializer where required, initialize preferences, register settings and
dispatches, subscribe to events, then log an unambiguous startup message.
Guard web-only modules and pages with `main::WEBUI` so a headless server can
still load the plugin.

If the plugin owns timers, subprocesses, subscriptions, sockets, overridden
methods, or temporary files, implement symmetric shutdown/uninstall behavior.
Assume a plugin can be disabled or reloaded without the LMS process exiting.
Make initialization idempotent: duplicate dispatches, wrappers, subscriptions,
and timers are common reload bugs.

## 3. Runtime design rules

LMS has a cooperative event loop. A plugin must not perform long network
requests, blocking subprocess waits, slow decoding, large filesystem work, or
unbounded database queries in a request handler or timer callback. Use LMS
timers to poll small units of work, nonblocking I/O, or an external worker and
deliver completion asynchronously.

For invasive observation or wrapping of an LMS method:

- call the original implementation first unless the contract explicitly
  requires otherwise;
- preserve scalar, list, and void context, return values, exceptions, mutable
  inputs, and side effects;
- copy data for observation instead of modifying the object LMS will consume;
- trap every observer error so optional plugin behavior cannot escape into
  playback or core request handling;
- install the wrapper once and restore it during shutdown where practical;
- re-check the exact LMS implementation for every supported version.

Keep memory, queues, database results, logs, and temporary storage bounded.
Use one state object per physical player when behavior is player-specific;
avoid global “current player” state. Synchronization groups, virtual players,
and control clients are not necessarily the physical playback endpoint.

Never assume a media URL traverses LMS. Depending on protocol handler,
transcoding, proxy settings, and player capabilities, the player may stream
directly or LMS may proxy/transcode. Test the actual data path and fail safely
when topology is ambiguous.

Use a dedicated log category such as `plugin.exampleplugin`. Log lifecycle,
state transitions, dispatch acceptance, terminal completion, timeouts, and
concise errors. Do not log credentials, cookies, authorization headers, raw
media, signed query strings, or entire third-party responses. Redact query
strings from URLs.

Plugin-writable data belongs below a runtime directory owned by the plugin, or
in an LMS-provided data location if the API requires it. Separate persistent
data from temporary files and caches. Use atomic write/rename for durable
outputs, validate all user-selected paths canonically, reject traversal and
symlink escapes, and never treat SQLite `-wal`/`-shm` files as backups.

## 4. CLI and control dispatches

Register commands with `Slim::Control::Request::addDispatch`. A handler should
validate the selected client and arguments, add explicit result fields, and
always reach a terminal request status.

For synchronous work, populate results and call `setStatusDone`. For genuinely
asynchronous control/UI work:

1. call `setStatusProcessing` before returning from the dispatch handler;
2. retain the request only as long as necessary;
3. complete it exactly once with results and `setStatusDone`;
4. add a watchdog that completes or cancels a stranded request.

Without `setStatusProcessing`, LMS can finish JSON-RPC immediately when the
handler returns. Without terminal completion, Material's loader or Jive's
inline wheel can remain forever.

Exercise commands through the local CLI without browser automation:

```bash
nc localhost 9090
```

LMS CLI arguments and results use percent escaping. Test missing player,
missing arguments, unknown subcommands, duplicate calls, failure paths, and
timeout behavior—not only success.

## 5. Menus, feeds, and UI extension points

Choose the extension point that matches the feature rather than injecting
generic web HTML. For a current track/player **More** row, the verified
extension point is `Slim::Menu::TrackInfo->registerInfoProvider`. For a
browsable application, an OPML-based plugin can expose a feed through the
superclass `initPlugin` call with a stable tag, weight, app flag, and icon.

Menu/feed rows are hashes, but their interpretation depends on the requesting
client. Common fields include:

- `name`: localized display label;
- `type`: semantic row type such as `text`;
- `url`: callback or browse target used by classic XMLBrowser paths;
- `actions`/`jive`: direct control-UI action metadata;
- `itemActions`: command metadata used by control clients;
- `nextWindow`: navigation behavior;
- `item_loop`, `offset`, and `count`: list response paging contract;
- `weblink`: an external link that compatible skins can open;
- `icon` or artwork fields: preferably an LMS-served/proxied URL.

Do not assume a feed is rebuilt for every selection. TrackInfo feeds can be
cached globally and can outlive the request that created them. A later
XMLBrowser action callback may contain the feed's query rather than the
original request's transport. If navigation must differ by transport, classify
it while the concrete `Slim::Control::Request` is executing or while result
rows are serialized—not from a stale feed callback.

### SB2 / traditional-button clients

Classic Squeezebox 2-style clients use XMLBrowser and URL callbacks. For an
asynchronous TrackInfo row, the reliable shape is a plain `name`, callback
`url`, and top-level `nextWindow => 'parent'`.

Do not advertise Jive actions or `itemActions` on a row intended for a
traditional button client. If present, SB2 can invoke the direct list command
instead of the callback, omit `isButton`, and enter a blank XMLBrowser page.
Completion should use the traditional `showBriefly` path with a `line`
payload; for a two-line match, the small upper line and large lower line have
different visual weight, so test their ordering on hardware.

A defensive direct-command fallback for source-less, connection-less cached
rows must return an `items` array even if it also schedules `showBriefly`.
Otherwise `Slim::Buttons::XMLBrowser` may dereference an undefined array and
leave a blank screen.

### SqueezePlay / Jive

Jive normally executes control actions through SqueezePlay/Comet. An
asynchronous list-shaped action can keep the current More-menu row selected
and replace its arrow with the native inline wheel while the request remains
pending.

For this behavior, omit `nextWindow` from both the action and the top-level
row. A top-level fallback can be inherited by the action and close the More
menu prematurely. On success, complete the pending action with a child list
response. Include `offset => 0`, an accurate `count`, and inert `item_loop`
rows. If `offset` is missing, SqueezePlay may refetch the action as an
unsatisfied page instead of settling the child window.

Jive can display multiple result rows or lines. Leave a normal manual Back
path. A re-entry into the menu action should start a new operation, not serve
as a result-polling mechanism.

### Material Skin

Material uses JSON-RPC and expects an item-specific list-shaped command for
native busy state. The pending request produces Material's native three-dot
loader. Put `nextWindow => 'parentNoRefresh'` on Material's `go` action so it
does not pre-push or replace the current browse view.

Complete only the initiating JSON-RPC request/connection. A sole inert result
row may also need `nextWindow => 'parentNoRefresh'` metadata to prevent
Material from wrapping it in browse-page HTML before presenting it. Material
notifications are single-line in practice; newline-delimited content may show
only the first field. Format compact results on one line and target the
selected physical player's ID.

The Material notification command is skin-specific, so use it only as a
fallback when Material is actually identified. Material timeout values are in
seconds. Do not broadcast a terminal result to unrelated browser connections.

### Transport detection and cached rows

Do not classify clients solely from `menuMode`. Both Material and Jive can use
numeric `menu=1`, and both can appear with named TrackInfo modes. Observed
transport is stronger evidence:

- request source `JSONRPC` indicates Material/control-web behavior;
- SqueezePlay/Comet sources indicate Jive;
- no source is ambiguous and must remain navigation-neutral unless the row is
  structurally known to be a traditional callback.

SqueezePlay may retain a TrackInfo request object whose handler pointer was
resolved before a plugin reload. It can also rebuild a control-menu feed with
no source. Preserve a neutral direct action on such control-menu rows, but do
not add that action to a true traditional row. Revalidate the transport when
the action executes and, when necessary, when LMS serializes the row for the
actual connection.

These are interoperability findings, not a promise that every plugin should
wrap request execution. Prefer a simpler native pattern copied from LMS core
when it satisfies all target clients; if transport-sensitive behavior is
needed, isolate and guard any wrapper carefully.

## 6. Loading indicators and asynchronous completion

Use the client's native loading indicator instead of sending a synthetic
“Working” or “Listening” popup:

| Client | Native pending state | Reliable terminal shape |
|---|---|---|
| SB2 / classic XMLBrowser | block animation | callback plus `showBriefly` `line` payload |
| SqueezePlay / Jive | inline wheel on selected row | completed child list with paging metadata |
| Material Skin | three-dot/fetching loader | terminal response on initiating JSON-RPC request |

The loader remains visible because the callback/request remains pending. The
operation must have both a domain deadline and a UI watchdog slightly beyond
it. Every accepted request must finish exactly once with success, explicit
no-result, cancellation, or a concise error. Playback changes, player removal,
plugin shutdown, and worker faults are completion paths too.

Duration units differ across APIs. In verified behavior, Material timeouts are
seconds, Jive payload duration is milliseconds, and the outer `showBriefly`
duration is seconds. Confirm units from the exact LMS implementation before
adding a new call.

## 7. Settings pages and preferences

Global settings modules normally subclass `Slim::Web::Settings`; player-scoped
settings do the same and return true from `needsClient`. Register their
instances during `initPlugin` only when `main::WEBUI` is available.

Use `Slim::Utils::Prefs::preferences('plugin.exampleplugin')`, initialize every
preference with a safe default, and return the preference object plus names
from the settings module's `prefs` method. For per-player values, use
`$prefs->client($client)` rather than encoding player IDs into global keys.

Settings page URIs and names should be CSRF-protected through
`Slim::Web::HTTP::CSRF`. Templates belong below:

```text
HTML/EN/plugins/ExamplePlugin/settings/
```

Build pages with LMS templates:

```text
[% PROCESS settings/header.html %]
[% WRAPPER setting title="TOKEN" desc="TOKEN_DESC" %]
    ...control...
[% END %]
[% PROCESS settings/footer.html %]
```

Control names for automatic preference persistence use `pref_...`. HTML
checkboxes are absent when unchecked, so explicitly set them to `0` in the
save handler when their parameter is undefined. Whitelist select values,
trim and length-limit text, and clamp numeric values server-side.

For native enhanced numeric sliders, use a text input rather than HTML
`type="number"`:

```html
<input type="text" class="stdedit sliderInput_5_30_1"
    name="pref_interval" value="[% prefs.interval | html %]" size="3" />
```

The class suffix is minimum, maximum, and step. The slider is presentation;
validation remains mandatory in Perl.

The native file picker is activated with classes such as:
`selectFile selectFile_sqlite3`. A `beforeRender` method can expand a portable
relative value into an absolute picker start path. On save, canonicalize and
validate the selection, then store a plugin-relative path so it can migrate to
Linux. A disabled HTML input is not posted; retain the existing saved value
explicitly if disabling one control from another.

Keep destructive or transactional buttons (backup, clear, migrate, test
connection) outside ordinary preference-save semantics. Require explicit
confirmation, report a status through the page, and leave prior working state
active on failure.

Test the global page, selected-player page, defaults on a clean preference
namespace, unchecked checkboxes, every boundary value, invalid/tampered form
values, disabled inputs, and behavior when the web UI is disabled.

## 8. Web assets, artwork, and links

Plugin web paths are convention-based and case-sensitive on Linux. Verify the
manifest icon and UI icons from every skin. A path that renders in the standard
web interface may still fail on a physical player or Material.

For dynamic or remote artwork, prefer serving it through an LMS plugin HTTP
handler and provide an absolute URL derived from LMS runtime configuration.
This lets LMS use its image proxy for remote players and control UIs. A
plugin-relative value can be misinterpreted as a filesystem path in some core
artwork paths. Use versioned URLs or appropriate cache headers when replacing
an image in place.

Use the row's native `weblink` field for external URLs where supported. Allow
only expected schemes, normalize URLs, remove tracking or signed query data
where appropriate, and escape all template output.

## 9. Testing on this Mac

Start with read-only and isolated checks:

```bash
git status --short
xmllint --noout install.xml
perl -Ilib t/example.t
tail -n 500 "/Users/dexi/Library/Logs/Squeezebox/server.log"
rg -n -i -C 8 "exampleplugin|plugin.exampleplugin|error|warn" \
  "/Users/dexi/Library/Logs/Squeezebox/server.log"
lsof -nP -iTCP:9000 -sTCP:LISTEN
lsof -nP -iTCP:9090 -sTCP:LISTEN
```

Use the bundled LMS Perl for narrow syntax checks when helpful, but interpret
failures carefully. Standalone compilation can report misleading bootstrap or
`JSON::XS` ABI errors because LMS has not initialized its custom library paths.
The actual LMS startup log is authoritative.

Before a restart, record the current listener PID and the tail of the startup
log. Restart only through an approved terminal mechanism. The bundled helper
uses paths relative to its current working directory: it assumes scripts are
in a parent directory and can stop LMS without relaunching it when called from
the wrong directory or a restricted environment. Run it from its own directory
or invoke it through a known wrapper that sets that directory.

After every restart, do not trust only the command exit status:

1. Resolve the process listening on ports 9000 and 9090 with `lsof`.
2. Confirm both ports belong to the same new/current `slimserver.pl` process.
3. Confirm the process start time/PID changed when a full restart was expected.
4. Inspect `server.log` from the restart boundary for manifest, compile,
   dependency, duplicate-registration, and plugin initialization errors.
5. Find the plugin's explicit startup message and version.
6. Issue a harmless plugin CLI status command.

An older supervised process may keep the ports while a newly launched test
process fails with “address already in use.” In that case the shell may have
started a process, but the old process is still serving old plugin code.

Do not erase caches as a routine reload strategy. Cache deletion hides lifecycle
bugs, destroys diagnostic evidence, and differs from production. Do not edit
LMS core, application bundles, server preferences, system Perl/Python, or other
plugins to make a test pass.

UI behavior must be checked manually on each target interface. Browser-only
success does not establish Jive or SB2 compatibility. For asynchronous rows,
verify entry navigation, pending indicator, success, no-result, error,
timeout, cancellation, Back behavior, repeat invocation, and that results are
scoped to the initiating client. Check logs while performing each test.

Playback-sensitive plugins require extra caution. Automated tests must not
stop, pause, seek, change tracks, alter proxy settings, create hidden players,
or modify synchronization groups. Ask the user to perform any necessary UI or
playback step, then inspect state and logs through the terminal.

## 10. Portable deployment to Linux

Develop against the Mac installation, but treat Linux as a distinct runtime:

- paths, user names, service accounts, and LMS directories differ;
- the filesystem is case-sensitive;
- path separators and permissions matter;
- the service has a smaller environment than an interactive shell;
- macOS executables and virtual environments cannot run on Linux;
- CPU architecture may differ;
- process supervision and restart commands are distribution-specific;
- LMS, Perl, skin, and plugin dependency versions may differ.

The plugin must derive its root and use `File::Spec`/`File::Basename`, never
assemble portable paths with hard-coded `/Users/...`. Keep persistent settings
relative or semantic whenever possible. Do not rely on Homebrew paths, a shell
profile, current working directory, GUI session, or inherited `PATH`.

Package source, templates, static assets, manifest, strings, and declared
dependency metadata. Exclude development and runtime material:

```text
.git/
python/venv/ or other host-built environments
var/tmp/
var/logs/
caches
captured/generated test evidence
credentials and local configuration
SQLite -wal and -shm sidecars
```

If the plugin has non-Perl dependencies, rebuild them on Linux under a
plugin-local environment or install them through the production host's
documented package process. Never copy a macOS virtual environment or binary.
Check executable permission and service-account read/write access. External
executable overrides should be explicit absolute paths and should fail with a
clear configuration error when invalid.

Preserve persistent data separately and use an application-consistent backup.
For SQLite, use the SQLite online backup API or a verified standalone backup,
especially when WAL mode is enabled. Test restore and schema migration before
production deployment.

On Linux, locate paths from the actual service configuration rather than
assuming the Mac layout. Common installations may use `/var/lib/squeezeboxserver`,
`/var/log/squeezeboxserver`, `/etc/squeezeboxserver`, and a systemd unit named
`logitechmediaserver` or `lyrionmusicserver`, but none is universal. Discover
the service, command line, preferences, plugin path, log path, and service user
first. Then:

1. back up the existing plugin and persistent data;
2. copy/install the new plugin with correct ownership and modes;
3. rebuild host-specific dependencies;
4. validate manifest and dependency availability;
5. restart through the host's real supervisor;
6. verify PID, listening ports, log startup, plugin version, and a safe CLI
   command;
7. run the client/UI compatibility matrix before declaring success;
8. keep a rollback package and documented rollback procedure.

Do not use a development-only min/max LMS manifest range to imply Linux
compatibility. Compatibility depends on LMS code version and behavior, not the
operating-system label alone.

## 11. Review checklist for every LMS plugin change

- Manifest XML is valid; module, package, web paths, and filename case match.
- Plugin initializes once, logs its version, and cleans up owned resources.
- No slow or blocking work runs in the LMS event loop.
- All per-player state is keyed to the correct physical player.
- CLI/control requests validate input and terminate exactly once.
- Async UI has deadlines and completes on every error/cancellation path.
- TrackInfo/menu rows are tested separately on SB2, Jive, and Material.
- Navigation metadata is based on transport, not only `menuMode`.
- Jive list responses include `offset`, `count`, and `item_loop`.
- Traditional rows do not accidentally expose control-UI actions.
- Settings persist checked and unchecked states and validate server-side.
- Numeric controls use LMS slider classes; paths remain portable.
- Templates, strings, links, and artwork are escaped and case-correct.
- Runtime files, secrets, databases, caches, and host-built dependencies are
  excluded from source control and deployment packages as appropriate.
- Restart verification proves the serving PID loaded the new code.
- Logs contain useful lifecycle evidence without sensitive data.
- Linux service user permissions, environment, architecture, paths, backup,
  migration, and rollback have been tested.

## 12. What remains empirical

The UI contracts above were discovered against LMS 9.1.0 and the client/skin
versions installed or tested with this development server. They are valuable
regression requirements, but they are not universal API guarantees. Reinspect
the relevant LMS and skin source and repeat the client matrix when upgrading
LMS, Material Skin, SqueezePlay/Jive, or deploying to materially different
hardware.

