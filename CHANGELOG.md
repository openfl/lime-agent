# Changelog

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
