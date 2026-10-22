# lime-agent

lime-agent lets a coding agent (Claude Code, Codex, Cursor and others) look at, read and drive a Lime app while you develop it. The agent can take a screenshot of your app's window, read its UI as a list of controls, read its logs and errors with stack traces, and click, type, press keys and scroll.

It works with plain Lime, OpenFL, Feathers UI and Graphaxe apps. You add one haxelib and set an environment variable when you launch a development build. Nothing about how the app is built changes.

## What MCP is

MCP (Model Context Protocol) is a standard way for coding agents to use tools. An MCP server is a small program the agent starts on your machine and talks to over its standard input and output. It lists tools ("screenshot", "click"...), and the agent calls them while it works, the same way it reads files or runs commands.

lime-agent has two parts:

- **The library**, compiled into your app. When you launch the app with `LIME_AGENT=1`, it listens on `127.0.0.1` for requests from the MCP server and answers them from inside the app's frame loop.
- **The MCP server**, `haxelib run lime-agent mcp`. Your agent starts it. It finds running apps through a small per-user registry and turns each tool call into a request to the app.

```
Claude Code <-- stdin/stdout --> lime-agent mcp <-- 127.0.0.1 + token --> your app (LIME_AGENT=1)
```

## Install

```bash
haxelib install lime-agent
```

From a checkout instead:

```bash
haxelib dev lime-agent path/to/lime-agent
haxe run.hxml
```

(`haxe run.hxml` builds `run.n`, the MCP server that `haxelib run` starts.)

## Enable it in your app

Add the haxelib to `project.xml`:

```xml
<haxelib name="lime-agent" />
```

or `-lib lime-agent` in an hxml build. That is the only change. Builds made with `-final` leave it out.

Launch with the agent turned on:

```bash
LIME_AGENT=1 LIME_AGENT_INPUT=1 lime test windows
```

In PowerShell:

```powershell
$env:LIME_AGENT = '1'; $env:LIME_AGENT_INPUT = '1'; lime test windows
```

`LIME_AGENT=1` lets agents look (screenshot, UI tree, logs, errors). `LIME_AGENT_INPUT=1` also lets them click, type, press keys and scroll; leave it out when you only want the agent to watch. On start the app prints a line like `[lime-agent listening on 127.0.0.1:50916, input on]`.

## Connect your agent

The command is the same everywhere: `haxelib run lime-agent mcp`.

**Claude Code**

```bash
claude mcp add lime-agent -- haxelib run lime-agent mcp
```

Add `--scope project` to save it in the project's `.mcp.json`, so everyone working on the project gets it. Run `/mcp` inside Claude Code to check that it is connected.

**Codex**

```bash
codex mcp add lime-agent -- haxelib run lime-agent mcp
```

or in `~/.codex/config.toml`:

```toml
[mcp_servers.lime-agent]
command = "haxelib"
args = ["run", "lime-agent", "mcp"]
```

**Cursor**, in `.cursor/mcp.json`:

```json
{
	"mcpServers": {
		"lime-agent": {"command": "haxelib", "args": ["run", "lime-agent", "mcp"]}
	}
}
```

Then ask in plain words, for example: "Take a screenshot of my app and tell me why the Save button is cut off", or "Click Start, wait, and tell me what errors were logged."

To see what the MCP server sees, run `haxelib run lime-agent list` in a terminal.

## Tools

| Tool | What it does |
| --- | --- |
| `list_apps` | Running apps with lime-agent on, their window size, whether input is allowed, and recent crashes |
| `screenshot` | The app's window as an image |
| `ui_tree` | The UI as an outline: kind, name, text and bounds of each control |
| `click` | Click at a point (left, right or middle; double-click) |
| `type` | Type text into the focused control |
| `key` | Press a key, with ctrl, shift, alt or meta |
| `scroll` | Scroll with the mouse wheel, optionally at a point |
| `logs` | `trace` output and Lime log messages |
| `errors` | Errors with stack traces; for an app that crashed, its crash record |
| `wait_idle` | Wait until the app has handled the input and settled |

Coordinates are pixels in the screenshot, so an agent clicks where it sees something. With one app running, tools use it; with several, they take an `app` argument (the pid or part of the name).

Input goes through Lime's own window events, the same path as a real mouse and keyboard, so your app's handlers run exactly as they would for a person.

## Security

lime-agent is for development builds on your own machine.

- **Off unless you turn it on.** Without `LIME_AGENT=1` the app opens no socket. `-final` builds do not contain it at all.
- **Watching and driving are separate.** Input needs `LIME_AGENT_INPUT=1` as well.
- **Loopback only.** The app listens on `127.0.0.1`, never on a network interface.
- **A token on every request.** Each launch makes a new random 32-byte token. It is written only to the registry file, which only your user can read (`%LOCALAPPDATA%\lime-agent\apps` on Windows; a `0700` directory with `0600` files on macOS and Linux). If the app cannot make the directory private, it does not write the token.
- **Browsers are refused.** Any request with an `Origin` header, a `Host` other than the loopback address, or a non-JSON body is refused, so a web page cannot reach the app even if it guesses the port.
- **No files, no commands.** The app answers only the operations listed above. It reads and writes no files except its own registry entry and crash record, and runs nothing.
- **Sensitive screens are blocked.** Password fields are reported as `[masked]`. An app can mark a moment as sensitive (`LimeAgent.sensitive`), which blocks screenshots, the UI tree and input until it ends.
- **The screenshot is the app's own framebuffer.** Other windows and the rest of your desktop are never captured.

## Optional: tell the agent more

Nothing below is required. Wrap calls in `#if lime_agent` if the haxelib is not always present.

```haxe
import limeagent.LimeAgent;

LimeAgent.sensitive = () -> settingsPanel.visible;     // block inspection and input while true
LimeAgent.busy = () -> loader.pending > 0;            // wait_idle waits while true
LimeAgent.addInfo("level", () -> game.levelName);     // extra facts in list_apps / info
LimeAgent.addCommand("restart_level", args -> {       // an action agents can run by name
	game.restart();
	return {ok: true};
});
LimeAgent.reportError(error);                         // an error you caught but want the agent to see
LimeAgent.capture = window -> renderer.capture();     // for renderers readPixels cannot see (Vulkan)
LimeAgent.addAdapter(new MyTreeAdapter());            // a UI tree for a custom framework
```

OpenFL, Feathers UI and Graphaxe UI trees are built in. A plain Lime app has no display list, so it shows a UI tree only if it adds an adapter; `samples/basic` shows how.

## Limits

- Native desktop builds through hxcpp (Windows, macOS, Linux). HTML5 cannot listen on a socket; HashLink is not supported yet.
- The app answers from its frame loop. If the loop is stuck, the tools say the app is not responding, which is often the clue you need.
- Screenshots read the window's OpenGL framebuffer. Vulkan windows need `LimeAgent.capture` or a framework adapter that captures (Graphaxe's does).
- When an app dies on an uncaught exception, lime-agent writes a crash record first, and `errors` returns it. On Windows the dying app may show its own error box until you close it.

## Tests

The tests need no network beyond loopback and make no API calls.

```bash
haxe run.hxml
haxelib run lime build samples/basic windows
haxelib run lime build samples/feathers windows
haxe tests.hxml
```

They launch the samples, check every endpoint (including the security refusals), drive the samples through the MCP server, and crash them on purpose to check the crash record.

## Protocol

The endpoint protocol, registry format and the plan for hot reload are in [docs/design.md](docs/design.md).
