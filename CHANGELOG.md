# Changelog

## 0.3.0 - 2026-10-24

### Added

- A `drag` tool: press at `fromX, fromY`, move to `toX, toY` in `steps` moves (10 by default), one a frame, and
  release there, through the app's own mouse events like `click`. `holdMs` holds the button at the start first, for
  apps that wait for a long press. It needs `LIME_AGENT_INPUT=1`, as all input does, and works with apps on 0.2.0.
- `LimeAgent.label`, a function that names display objects in the UI tree ("card KH", "pile t3"). A labelled object is
  always listed, in the OpenFL, Feathers UI and Graphaxe trees.
- Tree nodes say whether a click reaches them: `pointer: false` for an object that lets clicks through, `covered` for
  one other objects hide completely, and `at`, a point that reaches it, when its centre is covered. `hidden` marks the
  invisible objects that `includeHidden` lists.
- `maxDepth` (30 by default) bounds the tree as `maxNodes` does, and `more` on a node counts the children either left
  out. `ui_tree` takes both.
- `samples/graphaxe`, a Graphaxe scene of cards to drag onto a pile, and tests that drive it.

### Changed

- The Graphaxe tree lists every visible object, not only controls and named objects, so a game's sprites, quads and
  images show with their class, name, label, text and bounds. Bounds are the object's bounds on the stage, so a
  rotated or pivoted object is placed right.

## 0.2.0 - 2026-10-24

### Changed

- The endpoint runs on [crossbyte](https://github.com/dimensionscapeorg/crossbyte): its `HTTPServer` for HTTP and its
  `ServerWebSocket` for the WebSocket, in a crossbyte runtime advanced from the app's frame loop, or in the app's own
  runtime when it already runs crossbyte. lime-agent's own HTTP server is gone. The HTTP protocol, its checks and its
  answers are the same as before, so the MCP server and scripts written for 0.1.0 work unchanged.
- lime-agent depends on crossbyte 1.0.0 and [libhxcpp](https://github.com/openfl/libhxcpp). Native builds use libhxcpp,
  not stock hxcpp: stock hxcpp is outdated, and crossbyte needs libhxcpp. (Upgrading)
- The launch line names both ports: `[lime-agent listening on 127.0.0.1:50916 (WebSocket 50917), input on]`.
- Tokens come from crossbyte's `SecureRandom`.
- A request with a chunked body is read, within the same 64 KB limit, where 0.1.0 answered it 411.

### Added

- A WebSocket on a second loopback port, `ws://127.0.0.1:<wsPort>/lime-agent/v1`. The upgrade gets the same checks as
  every HTTP request: the bearer token, a loopback `Host` and no browser `Origin`. A message is
  `{"id", "op", "args"}`, answered with `{"id", "status", "result"}` or `{"id", "status", "error"}`, the status being
  the one the same call gets over HTTP. Several calls can be in flight on one connection, each answered when it
  finishes.
- `subscribe` on the WebSocket, with `events: ["log", "error"]`, pushes each log line and error as the app records it.
- `wsPort` in the registry entry, and `LIME_AGENT_WS_PORT` for a fixed WebSocket port.

### Upgrading

- `haxelib install lime-agent` installs crossbyte and libhxcpp. Then run `haxelib run libhxcpp setup` once, so the
  Haxe compiler and Lime build with libhxcpp wherever they ask for hxcpp. libhxcpp's README says how to switch back.

## 0.1.0 - 2026-10-23

First development release: screenshot, UI tree, logs, errors, input and an MCP server.
