# lime-agent design (phase 1)

lime-agent lets a coding agent look at, read and drive a running Lime app while you develop it. It has two halves:

- **The library**, compiled into a development build of the app. It serves a loopback endpoint, HTTP and a WebSocket, from the app's own frame loop, using crossbyte.
- **The MCP server** (`haxelib run lime-agent mcp`), started by Claude Code, Codex or Cursor. It finds running apps through a per-user registry and turns the endpoint into MCP tools.

Phase 1 changes nothing in an app's code: add the haxelib, launch with `LIME_AGENT=1`. Native builds use libhxcpp, which crossbyte needs (section 7). Phase 2 (a CPPIA hot-reload runtime that may ship with Lime) plugs into the same registry, protocol and tools.

Phase 1 targets native desktop builds through libhxcpp (Windows, macOS, Linux). HTML5 has no listening sockets. HashLink and Neko would need a secure random source and `chmod`, and are left for later.

## 1. Opting in

| Step | What it does |
| --- | --- |
| `<haxelib name="lime-agent" />` in `project.xml` (or `-lib lime-agent`) | Compiles the agent in. The haxelib's `include.xml` and `extraParams.hxml` add one init macro. Builds made with `-final`, or with `-D lime-agent-disable`, compile nothing. |
| `LIME_AGENT=1` in the launch environment | Starts the endpoint. Without it the agent does nothing: no socket, no hooks, no registry entry. `-D lime-agent-autostart` does the same at compile time. |
| `LIME_AGENT_INPUT=1` (or `-D lime-agent-input`) | Additionally allows input. Without it the app can be watched, not driven. |

Optional: `LIME_AGENT_PORT` and `LIME_AGENT_WS_PORT` (1024 to 65535) and `LIME_AGENT_TOKEN` (24 characters or more) for scripts that want fixed ports and a fixed token. Otherwise the app binds two free ports and makes a 32-byte random token from crossbyte's `SecureRandom`, the system's secure random source.

The init macro adds `@:build` hooks to `lime.app.Application` (attach on construction, record a fatal error around `exec`) and `lime.utils.Log` (copy warnings and errors), and defines `HXCPP_STACK_TRACE` and `HXCPP_STACK_LINE` so release builds keep stacks (`-D lime-agent-no-stack` opts out). No app code changes are needed for the default behaviour.

## 2. Endpoint protocol (version 1)

HTTP/1.1 on `127.0.0.1:<port>`, one request per connection. Every request is:

```
POST /lime-agent/v1/<op>
Authorization: Bearer <token>
Content-Type: application/json
Host: 127.0.0.1:<port>    (or localhost:<port>)

{ ...arguments... }
```

Refused with 403 before anything else: a wrong or missing token, any `Origin` header, a `Host` that is not loopback with this port (DNS rebinding), a non-JSON content type (form CSRF). Methods other than POST get 405, bodies over 64 KB get 413 (chunked bodies are read, within the same limit). At most 4 connections; a request must arrive within 5 seconds.

Success is HTTP 200 with a JSON object. Failure is a non-200 status with `{"error": {"code": "...", "message": "..."}}`. Codes: `unauthorized` 403, `input_disabled` 403, `unknown_op` 404, `bad_request` 400, `too_large` 413, `sensitive` 423, `unsupported` 501 (no tree adapter), `unavailable` 503 (no window, or no frame within 3 seconds), `internal` 500.

All coordinates are **screenshot pixels**: the pixel grid of the PNG that `screenshot` returns. The app divides by the window scale before dispatching to Lime, so an agent can click exactly where it sees something.

| Op | Arguments | Result |
| --- | --- | --- |
| `info` | none | `protocol {version, min}`, `app {name, version, pid, title}`, `lime`, `frameworks`, `capabilities`, `window {width, height, scale, viewWidth, viewHeight}`, `frame`, `sensitive`, `busy`, `input`, `lastLog`, `lastError`, `extra` (app-supplied facts, left out while sensitive) |
| `screenshot` | none | `pngBase64`, `width`, `height` (always the view size) |
| `tree` | `maxNodes` (default 400), `includeHidden` | `adapter`, `width`, `height`, `truncated`, `nodes`: nested `{kind, name, text, x, y, width, height, enabled, focused, children}` |
| `input` | `events`: 1 to 200 of `{type: mouse_move \| mouse_down \| mouse_up \| wheel \| key_down \| key_up \| text, ...}`; the whole batch is validated before any is sent | `{frame}` once every event has been dispatched and two more frames have run |
| `logs` | `since` (sequence; 0 for the newest), `limit`, `minLevel` | `entries {seq, time, level, message, source}`, `next`, `dropped` (1000 kept) |
| `errors` | `since`, `limit` | `entries {seq, time, message, stack, fatal}`, `next`, `dropped` (100 kept) |
| `wait_idle` | `timeoutMs` (default 5000, max 30000), `quietFrames` (default 3) | `idle`, `frame`, `waitedMs`, and `reason` when not idle |
| `command` | `name`, `args` | whatever the app's handler returns |

Input events are dispatched one per frame through the window's own Lime events (`onMouseMove`, `onMouseDown`, `onMouseUp`, `onMouseWheel`, `onKeyDown`, `onKeyUp`, `onTextInput`), so a game polling input every frame sees a down and an up as separate frames. Keys are names (`a`, `enter`, `f5`, `left`...) with `modifiers: ["ctrl", "shift", "alt", "meta"]`. Mouse `button` is `left`, `middle` or `right`. Wheel `dx`/`dy` are steps; a positive `dy` scrolls down (the app sees Lime's usual sign, which is the opposite); `x`/`y` on a wheel event move the pointer first.

`wait_idle` answers when no input is queued, the app's `busy` hook (if any) is false, and both have held for `quietFrames` update ticks in a row. It counts updates, not renders, because OpenFL skips rendering unchanged frames.

`screenshot` is taken from the app's own framebuffer at the end of its render (a lowest-priority `window.onRender` listener calling `window.readPixels` with the window's framebuffer bound), never from the desktop. Other windows and overlays are never included. Frameworks that skip unchanged frames (OpenFL) are asked to render one. An adapter that can capture directly (Graphaxe renders its stage to a texture) answers at once instead. If the captured image differs from the view size it is scaled to it, so screenshot, tree and input always share one grid.

### WebSocket

The same ops over one connection, on a second port: `ws://127.0.0.1:<wsPort>/lime-agent/v1`, with `wsPort` in the registry entry. The upgrade request gets the HTTP checks: the bearer token in `Authorization`, a loopback `Host` with this port, and no `Origin` (every browser sends one, so pages cannot connect). A failed check answers the upgrade 403; another path, 404. At most 4 sessions; the upgrade must finish within 5 seconds; messages up to 64 KB.

Calls are text messages, `{"id": <any JSON value>, "op": "<op>", "args": {...}}`. Each is answered once, `{"id", "status", "result"}` on success or `{"id", "status", "error": {code, message}}` otherwise, with the status and code the same call gets over HTTP. A call that waits (`screenshot`, `input`, `wait_idle`) is answered when it finishes, so answers can come in another order than the calls: match them by `id`. A message that is not a JSON object with a string `op` is answered with `id` null and 400.

One op exists only here. `subscribe` with `{events: ["log", "error"]}` (either or both; a later `subscribe` replaces the list) answers `{events}`, then sends `{"event": "log", "entry": {seq, time, level, message, source}}` for each log line and `{"event": "error", "entry": {seq, time, message, stack, fatal}}` for each error, as the app records them, the error that ends the app included. Entries have the same `seq` as `logs` and `errors`, so a client that reconnects can page back with those ops.

**Versioning.** The version is in the path. A later v2 adds `/lime-agent/v2/...` and the app can keep serving v1. `info.protocol.min` says the oldest version the app still answers. New ops inside v1 are announced through `capabilities` and never change an existing op's meaning, so agents keep working.

**Capabilities** in v1: `info`, `screenshot`, `tree`, `logs`, `errors`, `wait_idle`, `input` (only when input is enabled), `command:<name>` per app command. Reserved for phase 2: `reload`, `state`.

## 3. Registry of running apps

A per-user directory with one file per running app:

| OS | Directory |
| --- | --- |
| Windows | `%LOCALAPPDATA%\lime-agent\apps` (the per-user profile ACL) |
| macOS | `~/Library/Application Support/lime-agent/apps` |
| Linux | `$XDG_RUNTIME_DIR/lime-agent/apps`, else `~/.local/state/lime-agent/apps` |
| Any (tests) | `LIME_AGENT_REGISTRY` |

`<pid>.json`: `{protocol, pid, name, title, port, wsPort, token, started, capabilities, lime, frameworks, exe}` (`started` in epoch milliseconds; `wsPort` from 0.2.0). Written atomically after the port is listening; deleted when the app exits. The MCP server prunes an entry whose port refuses connections or whose app rejects its token.

On macOS and Linux the directory is set to 0700 and the file to 0600, and the app reads the modes back. If they are still group or world accessible the token is not written; the endpoint still runs, reachable only by someone who has the token from the environment. Windows relies on the profile directory's ACL (the user, SYSTEM and Administrators).

When an app dies on an uncaught exception it writes `<pid>.crash.json` (message, stack, last 50 log lines, no token) before the process ends. The MCP server shows crash records from dead apps, prunes registry entries whose port no longer answers, and keeps the 10 newest crash records.

## 4. App-facing API

Nothing is required. For apps that want more, `limeagent.LimeAgent` (all no-ops when the agent is compiled out, so calls need no `#if`):

```haxe
LimeAgent.sensitive = () -> settingsPanel.isOpen;      // blocks screenshot, tree, input and commands; info leaves out extra
LimeAgent.busy = () -> loader.pending > 0;             // consulted by wait_idle
LimeAgent.addInfo("workspace", () -> store.root);      // extra facts in info
LimeAgent.addCommand("open_preferences", args -> {...}); // app-chosen actions, advertised as command:<name>
LimeAgent.reportError(error);                          // errors the app caught itself
LimeAgent.capture = window -> renderer.capture();      // replace readPixels (Vulkan, custom renderers)
LimeAgent.addAdapter(adapter);                         // custom UI tree, view size or capture
LimeAgent.setStateHooks(snapshot, restore);            // phase 2; stored, unused in phase 1
```

Adapters the app adds come first. Built-in tree adapters, picked automatically by what is compiled in (most specific first): **Graphaxe** (`gx.*` controls), **Feathers UI** (`feathers.controls.*`), **OpenFL** display list (any `DisplayObject`, `TextField` text). Password fields are always reported as `[masked]`. A plain Lime app without a framework has no tree unless it adds an adapter.

The library has no file access beyond its own registry and crash records, runs no commands, and serves no files.

## 5. MCP tools

`lime-agent mcp` is a stdio MCP server (JSON-RPC 2.0, one message per line). It talks only to loopback ports listed in the registry. Each tool takes an optional `app` (pid or part of the name); with exactly one app running it is used by default.

| Tool | Does |
| --- | --- |
| `list_apps` | Running apps (pid, name, title, size, capabilities, input on or off) and recent crashes |
| `screenshot` | The app's window as an image |
| `ui_tree` | The UI as an indented outline, one control per line with its bounds |
| `click` | Move, press, release at `x, y`; `button`, `double` |
| `type` | Committed text into the focused control |
| `key` | A key press with modifiers (`press`, `down` or `up`) |
| `scroll` | Wheel steps at an optional point |
| `logs` | Log lines since a sequence number |
| `errors` | Errors with stacks, including the crash record of an app that died |
| `wait_idle` | Wait until the app has settled after input |

A tool for a capability the app does not advertise returns a plain explanation instead of failing. Later capabilities (`reload`) get new tools in the MCP server; existing tools do not change.

## 6. Phase 2 seams

Phase 2 generalizes Phasor's `ClientHost`: a native host that loads the app as a CPPIA script, swaps it on a new build, and rolls back if the new script fails. Phase 1 leaves room for it:

- The host advertises `reload` and `state` in `capabilities` and the registry; agents discover it the same way.
- `reload` becomes a v1 op (`{force}` returning `{generation, accepted, error}`), the same shape as `ClientHost.requestReload` plus its result file, but over the authenticated endpoint instead of a marker file.
- `setStateHooks(snapshot, restore)` is ClientHost's `snapshot()` and `create(saved, true)` under a framework-neutral name.
- The endpoint, registry entry and log rings live in the native host, not in the script, so they survive a reload: the agent sees one app with an increasing `generation`, not a new pid.

## 7. Decisions for Chris

1. **crossbyte for the endpoint (changed in 0.2.0).** 0.1.0 had no dependency: its endpoint was a ~250-line loopback HTTP server on `sys.net.Socket`, since Lime could not ship a crossbyte dependency and crossbyte's native builds need libhxcpp. From 0.2.0 lime-agent depends on crossbyte 1.0.0 and libhxcpp, and serves HTTP with crossbyte's `HTTPServer` and the WebSocket with its `ServerWebSocket`. The reasons: stock hxcpp is outdated, crossbyte needs libhxcpp, and crossbyte brings the WebSocket and its pushed events without a second hand-written server. The runtime is a crossbyte `HostApplication` advanced from `Application.onUpdate`; an app that already runs crossbyte keeps its own, and the endpoint runs on it. The MCP server (`run.n`, on Neko) keeps a blocking client on `sys.net.Socket`: crossbyte's WebSocket client needs a secure random source that Neko lacks, and one request per tool call needs no event loop.
2. **Compiled in unless `-final`.** Adding the haxelib compiles the agent into debug and release builds; `-final` strips it. It still does nothing without `LIME_AGENT=1`. The stricter alternative is debug builds only.
3. **MCP server as `run.n`**, like Lime's own tools, so `haxelib run lime-agent mcp` works wherever Haxe is installed, with no separate download.

## 8. Status

Built and tested on Windows 10 with libhxcpp 6.0.0, crossbyte 1.0.0, Lime 8.4.0, OpenFL 9.5.2 and Feathers UI 1.3.0: `samples/basic` (plain Lime) and `samples/feathers` (OpenFL and Feathers UI) pass `haxe tests.hxml` over HTTP, the WebSocket and the MCP server. The Graphaxe adapter type-checks against Graphaxe's source but has not run against a Graphaxe app. The macOS and Linux paths (registry location, `chmod` and its check, `/dev/urandom`) have not been built yet.
