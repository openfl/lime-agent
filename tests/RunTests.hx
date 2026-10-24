package;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import sys.net.Host;
import sys.net.Socket;

/**
	Drives the sample app through the endpoint and through the MCP server. No network beyond loopback, no API calls.
	`haxe tests.hxml` after building the sample (`haxelib run lime build samples/basic windows`) and run.n (`haxe run.hxml`).
**/
class RunTests {
	static var root:String;
	static var exe:String;
	static var feathersExe:String;
	static var graphaxeExe:String;
	static var registry:String;
	static var apps:Array<Process> = [];
	static var failures = 0;

	static function main():Void {
		root = Sys.getCwd();
		exe = Path.join([root, "samples", "basic", "Export", switch Sys.systemName() {
			case "Windows": "windows/bin/LimeAgentSample.exe";
			case "Mac": "macos/bin/LimeAgentSample.app/Contents/MacOS/LimeAgentSample";
			default: "linux/bin/LimeAgentSample";
		}]);
		if (!FileSystem.exists(exe)) fatal('Build the sample first: $exe');
		feathersExe = StringTools.replace(StringTools.replace(exe, "basic", "feathers"), "LimeAgentSample", "LimeAgentFeathers");
		// Graphaxe builds into bin/ rather than Export/.
		graphaxeExe = StringTools.replace(StringTools.replace(StringTools.replace(exe, "basic", "graphaxe"), "Export", "bin"), "LimeAgentSample", "LimeAgentGraphaxe");
		if (!FileSystem.exists(Path.join([root, "run.n"]))) fatal("Build run.n first: haxe run.hxml");
		registry = Path.join([Sys.getEnv(Sys.systemName() == "Windows" ? "TEMP" : "TMPDIR") ?? "/tmp", "lime-agent-test-" + Std.random(0x7FFFFFFF)]);
		FileSystem.createDirectory(registry);
		Sys.putEnv("LIME_AGENT_REGISTRY", registry);
		try {
			endpoint();
			webSocket();
			mcp();
			if (FileSystem.exists(feathersExe)) feathers();
			else Sys.println("skip Feathers UI sample (not built: samples/feathers)");
			if (FileSystem.exists(graphaxeExe)) graphaxe();
			else Sys.println("skip Graphaxe sample (not built: samples/graphaxe)");
		} catch (error:Dynamic) {
			failures++;
			Sys.println("FAIL " + error + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
		}
		for (app in apps) try app.kill() catch (_:Dynamic) {}
		if (failures == 0) try {
			for (name in FileSystem.readDirectory(registry)) FileSystem.deleteFile(Path.join([registry, name]));
			FileSystem.deleteDirectory(registry);
		} catch (_:Dynamic) {}
		Sys.println(failures == 0 ? "All tests passed." : '$failures failure(s). Registry: $registry');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	// Endpoint

	static function endpoint():Void {
		var app = launch(false);
		var entry:Dynamic = app.entry;

		// Security: every refusal looks the same and comes before any work.
		expectStatus(request(entry, "info", "{}", ["Authorization" => "Bearer wrong-token-wrong-token-wrong"]), 403, "wrong token");
		expectStatus(request(entry, "info", "{}", ["Origin" => "https://example.invalid"]), 403, "browser origin");
		expectStatus(request(entry, "info", "{}", ["Host" => "evil.example:" + entry.port]), 403, "foreign Host (DNS rebinding)");
		expectStatus(request(entry, "info", "a=1", ["Content-Type" => "application/x-www-form-urlencoded"]), 403, "form content type");
		expectStatus(request(entry, "info", "{}", [], "GET"), 405, "GET");
		expectStatus(request(entry, "nothing", "{}"), 404, "unknown op");
		expectStatus(request(entry, "info", "[1]"), 400, "non-object body");
		expectStatus(request(entry, "info", "{" + StringTools.lpad("", " ", 70000) + "}"), 413, "oversized body");
		var unversioned = rawRequest(entry.port, 'POST /lime-agent/v2/info HTTP/1.1\r\nHost: 127.0.0.1:${entry.port}\r\nAuthorization: Bearer ${entry.token}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}');
		expectStatus(unversioned, 404, "unknown protocol version");
		ok("refuses wrong tokens, browser origins, foreign hosts, forms, other methods, unknown ops and versions, bad and oversized bodies");

		var info = call(entry, "info");
		check(info.protocol.version == 1 && info.protocol.min == 1, "protocol version");
		check(info.app.name == "Lime Agent Sample" && info.app.pid == entry.pid, "app identity");
		check(info.window.viewWidth == 640 * info.window.scale, "view size");
		var capabilities:Array<String> = info.capabilities;
		check(capabilities.indexOf("input") < 0 && capabilities.indexOf("screenshot") >= 0 && capabilities.indexOf("tree") >= 0, "capabilities without input");
		check(capabilities.indexOf("command:reset") < 0, "commands are hidden without input");
		check(entry.capabilities.indexOf("screenshot") >= 0 && entry.protocol == 1, "registry entry");
		ok("info reports protocol, identity, view size and capabilities; the registry entry matches");

		expectError(entry, "input", {events: [{type: "text", text: "x"}]}, 403, "input_disabled");
		expectError(entry, "command", {name: "reset"}, 403, "input_disabled");
		ok("inspection-only launches refuse input and commands");

		var shot = call(entry, "screenshot");
		var image = png(shot.pngBase64);
		check(image.width == shot.width && image.height == shot.height && image.width == info.window.viewWidth, "screenshot size");
		checkColor(image, 100, 60, 0x0066FF, "blue button");
		checkColor(image, 400, 300, 0x26262E, "background");
		ok("screenshot is the app's own framebuffer, right way up, at view size");

		var tree = call(entry, "tree");
		var nodes:Array<Dynamic> = tree.nodes;
		check(tree.adapter == "sample" && nodes[0].name == "counter" && nodes[0].text == "Clicked 0", "tree");
		ok("tree comes from the app's adapter");

		var logs = call(entry, "logs");
		check((logs.entries : Array<Dynamic>).filter(e -> StringTools.startsWith(e.message, "lime-agent listening")).length == 1, "startup log");
		check((call(entry, "errors").entries : Array<Dynamic>).length == 0, "no errors yet");
		ok("logs and errors start with the startup line and nothing else");
		close(app);
		check(FileSystem.exists(entry.path), "a killed app leaves its entry for the MCP server to prune");

		app = launch(true);
		entry = app.entry;
		var scale:Float = call(entry, "info").window.scale;
		function at(v:Float) return v * scale;
		send(entry, [{type: "mouse_move", x: at(100), y: at(60)}, {type: "mouse_down", x: at(100), y: at(60)}, {type: "mouse_up", x: at(100), y: at(60)}]);
		check(extra(entry).clicks == 1, "click counted");
		checkColor(png(call(entry, "screenshot").pngBase64), Math.round(at(100)), Math.round(at(60)), 0xFF8000, "orange button after one click");
		send(entry, [{type: "text", text: "hello"}, {type: "key_down", key: "backspace"}, {type: "key_up", key: "backspace"}]);
		check(extra(entry).typed == "hell", "text and backspace");
		var typed = png(call(entry, "screenshot").pngBase64);
		checkColor(typed, Math.round(at(60)), Math.round(at(170)), 0x00CC33, "bar for four characters");
		checkColor(typed, Math.round(at(90)), Math.round(at(170)), 0x26262E, "bar ends after four characters");
		send(entry, [{type: "wheel", dy: 3}]);
		check(extra(entry).wheel == -3, "wheel down is Lime's negative dy");
		send(entry, [{type: "key_down", key: "a", modifiers: ["ctrl"]}]);
		check(extra(entry).lastKey == "ctrl+97", "modifiers");
		ok("pointer, text, keys, modifiers and wheel reach the app through Lime's window events");

		expectError(entry, "input", {events: [{type: "mouse_down", x: 5000, y: 10}]}, 400, "bad_request");
		expectError(entry, "input", {events: [{type: "key_down", key: "nonsense"}]}, 400, "bad_request");
		expectError(entry, "input", {events: [{type: "teleport"}]}, 400, "bad_request");
		check(extra(entry).clicks == 1, "a rejected batch sends nothing");
		ok("invalid batches are rejected whole");

		check(call(entry, "command", {name: "reset"}).result.clicks == 0 && extra(entry).clicks == 0, "command");
		expectError(entry, "command", {name: "launch_missiles"}, 404, "unknown_op");
		ok("app commands run by name");

		send(entry, [{type: "key_down", key: "f2"}]); // busy for 0.5 s
		var waited = call(entry, "wait_idle", {timeoutMs: 100});
		check(waited.idle == false && waited.reason == "app busy", "wait_idle times out while busy");
		var idle = call(entry, "wait_idle", {timeoutMs: 3000});
		check(idle.idle == true && idle.waitedMs >= 200, "wait_idle waits for the busy hook");
		ok("wait_idle follows the app's busy hook and reports a timeout");

		send(entry, [{type: "key_down", key: "f3"}]); // sensitive for 1.5 s
		expectError(entry, "screenshot", {}, 423, "sensitive");
		expectError(entry, "tree", {}, 423, "sensitive");
		expectError(entry, "input", {events: [{type: "text", text: "x"}]}, 423, "sensitive");
		var hidden = call(entry, "info");
		check(hidden.sensitive == true && hidden.extra == null, "info hides app facts while sensitive");
		Sys.sleep(1.7);
		call(entry, "screenshot");
		ok("a sensitive view blocks screenshot, tree and input, then clears");

		send(entry, [{type: "key_down", key: "f4"}, {type: "key_down", key: "f5"}]);
		var errors:Array<Dynamic> = call(entry, "errors").entries;
		check(errors.length == 1 && errors[0].message == "sample reported error" && errors[0].fatal == false, "reported error");
		check((errors[0].stack : Array<String>)[0].indexOf("Main.onKeyDown") == 0, "reported error stack starts in the app");
		var warnings:Array<Dynamic> = call(entry, "logs", {minLevel: "warn"}).entries;
		check(warnings.filter(e -> e.message == "sample warning" && e.level == "warn").length == 1, "Lime warning");
		var paged = call(entry, "logs", {since: 1, limit: 1});
		check((paged.entries : Array<Dynamic>)[0].seq == 2 && paged.next == 2, "logs page forward");
		ok("reported errors carry stacks; Lime warnings and traces land in the log; logs page by sequence");

		// The crash cannot be answered; the record is the answer.
		try send(entry, [{type: "key_down", key: "f12"}]) catch (_:Dynamic) {}
		var crash = Path.join([registry, entry.pid + ".crash.json"]);
		waitFor(() -> FileSystem.exists(crash), 5, "crash record");
		var record = Json.parse(File.getContent(crash));
		check(record.message == "sample crash" && (record.stack : Array<String>)[0].indexOf("Main.onKeyDown") == 0, "crash record");
		check(File.getContent(crash).indexOf(entry.token) < 0, "crash record holds no token");
		check(!FileSystem.exists(entry.path), "a crashed app removes its registry entry");
		ok("an uncaught exception writes a crash record with its stack and recent logs");
		close(app);
	}

	// WebSocket

	static function webSocket():Void {
		var app = launch(true);
		var entry:Dynamic = app.entry;
		check(entry.wsPort != null && entry.wsPort != entry.port, "the registry entry has the WebSocket port");

		// The same refusals as HTTP, at the upgrade.
		check(WebSocketClient.upgrade(entry, ["Authorization" => "Bearer wrong-token-wrong-token-wrong"]) == 403, "wrong token");
		check(WebSocketClient.upgrade(entry, ["Origin" => "https://example.invalid"]) == 403, "browser origin");
		check(WebSocketClient.upgrade(entry, ["Host" => "evil.example:" + entry.wsPort]) == 403, "foreign Host (DNS rebinding)");
		check(WebSocketClient.upgrade(entry, [], "/lime-agent/v2") == 404, "unknown protocol version");
		ok("WebSocket upgrades refuse wrong tokens, browser origins, foreign hosts and other versions");

		var ws = new WebSocketClient(entry);
		var info = ws.call("info");
		check(info.status == 200 && info.result.app.pid == entry.pid && info.result.protocol.version == 1, "info over WebSocket");
		var scale:Float = info.result.window.scale;
		function at(v:Float) return v * scale;
		checkColor(png(ws.call("screenshot").result.pngBase64), Math.round(at(100)), Math.round(at(60)), 0x0066FF, "screenshot over WebSocket");
		var clicked = ws.call("input", {events: [{type: "mouse_move", x: at(100), y: at(60)}, {type: "mouse_down", x: at(100), y: at(60)}, {type: "mouse_up", x: at(100), y: at(60)}]});
		check(clicked.status == 200 && ws.call("info").result.extra.clicks == 1, "input over WebSocket");
		check(extra(entry).clicks == 1, "HTTP answers beside the WebSocket");
		ok("info, screenshot and input over a WebSocket, with HTTP answering beside it");

		var unknown = ws.call("nothing");
		check(unknown.status == 404 && unknown.error.code == "unknown_op", "unknown op: " + Json.stringify(unknown));
		var refused = ws.call("command", {name: "launch_missiles"});
		check(refused.status == 404 && refused.error.code == "unknown_op", "unknown command");
		ws.sendText("not json");
		var bad = ws.next();
		check(bad.status == 400 && bad.id == null && bad.error.code == "bad_request", "bad message: " + Json.stringify(bad));
		ok("WebSocket errors carry the status and code the same call gets over HTTP");

		send(entry, [{type: "key_down", key: "f2"}]); // busy for 0.5 s
		ws.send({id: "slow", op: "wait_idle", args: {timeoutMs: 3000}});
		ws.send({id: "fast", op: "info"});
		var first = ws.next(), second = ws.next();
		check(first.id == "fast" && second.id == "slow" && second.result.idle == true, "answers by id: " + first.id + ", " + second.id);
		ok("calls in flight together are answered as each finishes, matched by id");

		var subscribed = ws.call("subscribe", {events: ["log", "error"]});
		check(subscribed.status == 200 && (subscribed.result.events : Array<String>).join(",") == "log,error", "subscribe");
		check(ws.call("subscribe", {events: ["frames"]}).status == 400, "unknown events are refused");
		send(entry, [{type: "key_down", key: "f4"}, {type: "key_down", key: "f5"}]);
		var pushed:Array<Dynamic> = [];
		waitFor(() -> {
			pushed.push(ws.next());
			pushed.filter(m -> m.event == "error" && m.entry.message == "sample reported error").length == 1
				&& pushed.filter(m -> m.event == "log" && m.entry.level == "warn" && m.entry.message == "sample warning").length == 1;
		}, 10, "log and error events");
		check(pushed.filter(m -> m.event == "error")[0].entry.stack.length > 0, "a pushed error carries its stack");
		ok("subscribers get log and error events as they happen");

		try send(entry, [{type: "key_down", key: "f12"}]) catch (_:Dynamic) {}
		var fatal:Dynamic = null;
		waitFor(() -> {
			var message = ws.next();
			if (message.event == "error" && message.entry.fatal == true) fatal = message.entry;
			fatal != null;
		}, 10, "the fatal error event");
		check(fatal.message == "sample crash", "fatal event: " + Json.stringify(fatal));
		ok("a subscriber hears the error that ends the app before its connection closes");

		ws.close();
		close(app);
	}

	// MCP

	static function mcp():Void {
		var first = launch(true);
		// A dead app's entry: nothing listens on its port.
		var stale = Path.join([registry, "999999.json"]);
		File.saveContent(stale, Json.stringify({protocol: 1, pid: 999999, name: "Gone", port: freePort(), token: StringTools.lpad("", "x", 32)}));

		var mcp = new Mcp(root);
		var rpc = mcp.rpc, tool = mcp.tool, server = mcp.server;

		var init = rpc("initialize", {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: "test", version: "1"}}).result;
		check(init.protocolVersion == "2025-06-18" && init.serverInfo.name == "lime-agent" && init.capabilities.tools != null, "initialize");
		server.stdin.writeString('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
		check(rpc("initialize", {protocolVersion: "1999-01-01"}).result.protocolVersion == "2025-06-18", "unknown protocol version gets the latest");
		check(Reflect.fields(rpc("ping").result).length == 0, "ping");
		check(rpc("no/such/method").error.code == -32601, "unknown method");
		var names = [for (t in (rpc("tools/list").result.tools : Array<Dynamic>)) t.name];
		var expected = ["list_apps", "screenshot", "ui_tree", "click", "drag", "type", "key", "scroll", "logs", "errors", "wait_idle"];
		check(names.join(",") == expected.join(","), "tool list: " + names.join(","));
		ok("MCP handshake, ping, unknown methods and the tool list");

		var list = tool("list_apps");
		check(list.text.indexOf('pid ${first.entry.pid} "Lime Agent Sample"') >= 0 && list.text.indexOf("input on") >= 0, "list_apps: " + list.text);
		check(!FileSystem.exists(stale), "list_apps prunes the entry of an app that is gone");
		ok("list_apps finds the running app and prunes dead entries");

		var shot = tool("screenshot");
		check(shot.image != null && png(shot.image).width >= 640 && shot.text.indexOf("pixels") >= 0, "screenshot tool");
		var tree = tool("ui_tree");
		check(tree.text.indexOf('Button #counter "Clicked 0" [') >= 0, "ui_tree: " + tree.text);
		var counter = ~/Button #counter "Clicked 0" \[([0-9]+),([0-9]+) ([0-9]+)x([0-9]+)\]/;
		counter.match(tree.text);
		var cx = Std.parseInt(counter.matched(1)) + 10, cy = Std.parseInt(counter.matched(2)) + 10;
		check(!tool("click", {x: cx, y: cy}).isError, "click");
		check(tool("wait_idle").text.indexOf("Idle") == 0, "wait_idle tool");
		check(tool("ui_tree").text.indexOf('"Clicked 1"') >= 0, "click reached the button found in the tree");
		tool("type", {text: "abc"});
		tool("key", {key: "backspace"});
		tool("key", {key: "a", modifiers: ["ctrl"]});
		tool("scroll", {dy: 2, x: cx, y: cy});
		check(tool("ui_tree").text.indexOf('#typed "ab"') >= 0, "type and key");
		var logs = tool("logs");
		check(logs.text.indexOf("[trace] clicked 1") >= 0 && ~/next: [0-9]+/.match(logs.text), "logs tool");
		tool("key", {key: "f4"});
		check(tool("errors").text.indexOf("sample reported error") >= 0, "errors tool");
		var bad = tool("click", {x: 99999, y: 0});
		check(bad.isError && bad.text.indexOf("outside") >= 0, "an out-of-view click is a tool error");
		check(tool("frobnicate").isError, "unknown tool");
		ok("screenshot, ui_tree, click, type, key, scroll, logs, errors and wait_idle work through MCP");

		var scale:Float = call(first.entry, "info").window.scale;
		var chip = ~/Chip #chip \[([0-9]+),([0-9]+) ([0-9]+)x([0-9]+)\]/;
		check(chip.match(tool("ui_tree").text), "chip in the tree");
		var fromX = Std.parseInt(chip.matched(1)) + Std.parseInt(chip.matched(3)) / 2, fromY = Std.parseInt(chip.matched(2)) + Std.parseInt(chip.matched(4)) / 2;
		var toX = fromX + 150, toY = fromY + 60;
		var dragged = tool("drag", {fromX: fromX, fromY: fromY, toX: toX, toY: toY, steps: 5});
		check(!dragged.isError && dragged.text.indexOf("Dragged left") == 0, "drag: " + dragged.text);
		function point(x:Float, y:Float) return '${Math.round(x / scale)},${Math.round(y / scale)}';
		var path:Array<String> = call(first.entry, "info").extra.drag;
		check(path.length == 7 && path[0] == "down " + point(fromX, fromY) && path[6] == "up " + point(toX, toY), "down, five moves, up: " + path.join("; "));
		check(path.slice(1, 6).filter(e -> StringTools.startsWith(e, "move ")).length == 5 && path[5] == "move " + point(toX, toY), "moves along the path: " + path.join("; "));
		var xs = [for (e in path) Std.parseInt(e.split(" ")[1].split(",")[0])];
		check([for (i in 1...xs.length) xs[i] >= xs[i - 1]].indexOf(false) < 0, "the path runs from start to end");
		checkColor(png(tool("screenshot").image), Math.round(toX), Math.round(toY), 0x9933CC, "the chip where it was dropped");
		check(chip.match(tool("ui_tree").text) && Math.abs(Std.parseInt(chip.matched(1)) - (toX - 20 * scale)) <= 1, "the tree shows the chip where it was dropped");
		var held = tool("drag", {fromX: toX, fromY: toY, toX: fromX, toY: fromY, holdMs: 300});
		path = call(first.entry, "info").extra.drag;
		check(!held.isError && path.length == 12 && path[0] == "down " + point(toX, toY) && path[11] == "up " + point(fromX, fromY), "held drag: " + path.join("; "));
		check(tool("drag", {fromX: 1, fromY: 1, toX: 99999, toY: 1}).isError, "a drag that ends outside the view is refused");
		ok("drag presses, moves one step a frame and releases where it was asked, and the app sees each in order");

		var second = launch(false);
		var ambiguous = tool("screenshot");
		check(ambiguous.isError && ambiguous.text.indexOf("Several apps") >= 0, "two apps need a selector");
		check(tool("screenshot", {app: Std.string(second.entry.pid)}).image != null, "select by pid");
		var refused = tool("type", {app: Std.string(second.entry.pid), text: "x"});
		check(refused.isError && refused.text.indexOf("LIME_AGENT_INPUT=1") >= 0, "input refusal explains how to enable it");
		var noDrag = tool("drag", {app: Std.string(second.entry.pid), fromX: 10, fromY: 10, toX: 20, toY: 20});
		check(noDrag.isError && noDrag.text.indexOf("LIME_AGENT_INPUT=1") >= 0, "drag needs input enabled");
		close(second);
		ok("with two apps, tools ask which one; pids select; input refusals say how to enable input");

		tool("key", {key: "f12"});
		var crash = Path.join([registry, first.entry.pid + ".crash.json"]);
		waitFor(() -> FileSystem.exists(crash), 5, "crash record");
		close(first);
		var after = tool("errors");
		check(after.text.indexOf("not running") >= 0 && after.text.indexOf("sample crash") >= 0 && after.text.indexOf("Main.onKeyDown") >= 0, "crash via errors: " + after.text);
		check(tool("list_apps").text.indexOf("Recent crashes") >= 0, "list_apps shows the crash");
		ok("after a crash, errors returns the crash record with its stack");

		server.stdin.close();
		check(server.exitCode() == 0, "the MCP server exits when stdin closes");
		ok("the MCP server exits cleanly at end of input");
	}

	// OpenFL and Feathers UI

	static function feathers():Void {
		var app = launch(true, feathersExe);
		var entry:Dynamic = app.entry;
		var info = call(entry, "info");
		check((info.frameworks : Array<String>).filter(f -> StringTools.startsWith(f, "feathersui ")).length == 1, "frameworks");
		var tree = call(entry, "tree");
		check(tree.adapter == "feathersui", "Feathers adapter chosen over OpenFL");
		var nodes:Array<Dynamic> = tree.nodes;
		function find(name:String):Dynamic {
			var found = nodes.filter(n -> n.name == name);
			check(found.length == 1, 'one node named $name in ' + Json.stringify(nodes));
			return found[0];
		}
		check(find("password").text == "[masked]", "password fields are masked");
		check(find("save").text == "Save" && find("save").kind == "Button", "button text");
		check(nodes.filter(n -> n.kind == "TextField").length == 0, "text fields inside controls are not repeated");
		ok("the Feathers UI tree lists controls by their own text and masks passwords");

		// A static OpenFL scene skips rendering; a screenshot must still get a frame.
		var shot = png(call(entry, "screenshot").pngBase64);
		check(shot.width == info.window.viewWidth && shot.height == info.window.viewHeight, "OpenFL screenshot size");
		ok("screenshots of an unchanged OpenFL stage still render a frame");

		function center(node:Dynamic):Dynamic return {x: node.x + node.width / 2, y: node.y + node.height / 2};
		var name = center(find("name")), save = center(find("save"));
		send(entry, [{type: "mouse_move", x: name.x, y: name.y}, {type: "mouse_down", x: name.x, y: name.y}, {type: "mouse_up", x: name.x, y: name.y},
			{type: "text", text: "Ada"}, {type: "mouse_move", x: save.x, y: save.y}, {type: "mouse_down", x: save.x, y: save.y}, {type: "mouse_up", x: save.x, y: save.y}]);
		call(entry, "wait_idle");
		nodes = call(entry, "tree").nodes;
		check(find("name").text == "Ada" && find("status").text == "Saved Ada", "typed and saved: " + Json.stringify(nodes));
		ok("clicking tree coordinates and typing drive Feathers controls");

		var crash = center(find("crash"));
		try send(entry, [{type: "mouse_move", x: crash.x, y: crash.y}, {type: "mouse_down", x: crash.x, y: crash.y}, {type: "mouse_up", x: crash.x, y: crash.y}]) catch (_:Dynamic) {}
		var path = Path.join([registry, entry.pid + ".crash.json"]);
		waitFor(() -> FileSystem.exists(path), 5, "crash record");
		var record = Json.parse(File.getContent(path));
		check(record.message == "feathers crash", "crash message");
		check((record.logs : Array<String>).filter(l -> l == "[error] feathers crash").length == 1, "OpenFL's uncaught error and the crash are one error");
		ok("an uncaught error in an OpenFL handler is recorded once, as the crash");
		close(app);
	}

	// Graphaxe

	static function graphaxe():Void {
		var app = launch(true, graphaxeExe);
		var entry:Dynamic = app.entry;
		var tree = call(entry, "tree");
		check(tree.adapter == "graphaxe", "Graphaxe adapter");
		function all(nodes:Array<Dynamic>):Array<Dynamic> {
			var list = [];
			for (node in nodes) {
				list.push(node);
				if (node.children != null) list = list.concat(all(node.children));
			}
			return list;
		}
		function one(nodes:Array<Dynamic>, test:Dynamic->Bool, what:String):Dynamic {
			var found = all(nodes).filter(test);
			check(found.length == 1, 'one $what in ' + Json.stringify(nodes));
			return found[0];
		}
		var nodes:Array<Dynamic> = tree.nodes;
		var ace = one(nodes, n -> n.label == "card AS", "card AS");
		var king = one(nodes, n -> n.label == "card KH", "card KH");
		var queen = one(nodes, n -> n.name == "queen", "queen");
		check(ace.kind == "Card" && ace.x == 60 && ace.y == 60 && ace.width == 80 && ace.height == 110, "the ace's class and bounds: " + Json.stringify(ace));
		check((ace.children : Array<Dynamic>).filter(c -> c.kind == "TextField" && c.text == "A").length == 1, "the ace's rank");
		check(queen.kind == "Card" && queen.label == null && king.x == 80 && king.y == 90, "names, labels and bounds");
		check(king.at == null && king.covered == null && ace.at != null && ace.at.y < 90, "the ace's centre is under the king, its top edge is not: " + Json.stringify(ace));
		check(one(nodes, n -> n.name == "shine", "shine").pointer == false, "a decoration that lets clicks through");
		check(one(nodes, n -> n.name == "reset", "reset").text == "Reset", "a button by its text");
		check(all(nodes).filter(n -> n.name == "secret").length == 0, "hidden objects are left out");
		check(one(call(entry, "tree", {includeHidden: true}).nodes, n -> n.name == "secret", "secret").hidden == true, "and listed as hidden when asked");
		var shot = png(call(entry, "screenshot").pngBase64);
		check(shot.width == tree.width && shot.height == tree.height, "screenshot and tree share one grid");
		checkColor(shot, king.x + 60, king.y + 60, 0xCC2222, "the king where the tree puts it");
		checkColor(shot, queen.x + 60, queen.y + 90, 0x2244CC, "the queen where the tree puts it");
		ok("the Graphaxe tree lists game objects by class, name, label and text, with bounds that match the screenshot");

		var small = call(entry, "tree", {maxNodes: 3});
		check(small.truncated == true && all(small.nodes).filter(n -> n.more != null && n.more > 0).length > 0, "maxNodes: " + Json.stringify(small.nodes));
		var shallow:Array<Dynamic> = call(entry, "tree", {maxDepth: 1}).nodes;
		check(shallow.filter(n -> n.children == null && n.more != null).length > 0, "maxDepth: " + Json.stringify(shallow));
		ok("maxNodes and maxDepth bound the tree and say how many children were left out");

		var mcp = new Mcp(root);
		var text = mcp.tool("ui_tree").text;
		check(~/Card \(card AS\) \[60,60 80x110\] click at [0-9]+,[0-9]+/.match(text) && ~/Quad #shine \[[0-9, x]+\] no-pointer/.match(text), "ui_tree text: " + text);
		var pileX = 530, pileY = 105;
		// The ace by its visible edge, dropped so its centre lands on the pile.
		check(!mcp.tool("drag", {fromX: ace.at.x, fromY: ace.at.y, toX: pileX + ace.at.x - 100, toY: pileY + ace.at.y - 115}).isError, "drag the ace");
		mcp.tool("wait_idle");
		check(!mcp.tool("drag", {fromX: king.x + 40, fromY: king.y + 55, toX: pileX, toY: pileY}).isError, "drag the king");
		mcp.tool("wait_idle");
		var cards:Array<Dynamic> = call(entry, "info").extra.cards;
		check(cards.filter(c -> c.label != null && c.x == 490 && c.y == 50).length == 2, "both cards on the pile: " + Json.stringify(cards));
		var logs = mcp.tool("logs").text;
		check(logs.indexOf("card AS on the pile") >= 0 && logs.indexOf("card KH on the pile") >= 0, "the app saw both drops: " + logs);
		nodes = call(entry, "tree").nodes;
		check(one(nodes, n -> n.label == "card AS", "card AS").covered == true, "the ace is now covered by the king");
		checkColor(png(call(entry, "screenshot").pngBase64), pileX + 30, pileY + 40, 0xCC2222, "the king on top of the pile");
		var reset = one(nodes, n -> n.name == "reset", "reset");
		mcp.tool("click", {x: reset.x + reset.width / 2, y: reset.y + reset.height / 2});
		mcp.tool("wait_idle");
		cards = call(entry, "info").extra.cards;
		check(cards.filter(c -> c.x == 490).length == 0, "reset: " + Json.stringify(cards));
		ok("drag moves Graphaxe cards by their pointer events and drops them where asked; covered cards say so");
		mcp.close();
		close(app);
	}

	// Apps

	static function launch(input:Bool, ?path:String):{process:Process, entry:Dynamic} {
		var before = [for (name in FileSystem.readDirectory(registry)) name];
		Sys.putEnv("LIME_AGENT", "1");
		Sys.putEnv("LIME_AGENT_INPUT", input ? "1" : "");
		var process = new Process(path == null ? exe : path, []);
		apps.push(process);
		var entry:Dynamic = null;
		waitFor(() -> {
			for (name in FileSystem.readDirectory(registry)) if (before.indexOf(name) < 0 && ~/^[0-9]+\.json$/.match(name)) {
				entry = Json.parse(File.getContent(Path.join([registry, name])));
				entry.path = Path.join([registry, name]);
				return true;
			}
			return false;
		}, 20, "the sample app to register");
		return {process: process, entry: entry};
	}

	static function close(app:{process:Process, entry:Dynamic}):Void {
		try app.process.kill() catch (_:Dynamic) {}
		try app.process.close() catch (_:Dynamic) {}
		apps.remove(app.process);
		Sys.sleep(0.3);
	}

	// HTTP

	static function request(entry:Dynamic, op:String, body:String, ?headers:Map<String, String>, method = "POST"):{status:Int, body:String} {
		var all = ["Host" => '127.0.0.1:${entry.port}', "Authorization" => 'Bearer ${entry.token}', "Content-Type" => "application/json"];
		if (headers != null) for (key => value in headers) all.set(key, value);
		var head = '$method /lime-agent/v1/$op HTTP/1.1\r\n';
		for (key => value in all) head += '$key: $value\r\n';
		return rawRequest(entry.port, head + 'Content-Length: ${Bytes.ofString(body).length}\r\nConnection: close\r\n\r\n' + body);
	}

	static function rawRequest(port:Int, text:String):{status:Int, body:String} {
		var socket = new Socket();
		socket.setTimeout(15);
		socket.connect(new Host("127.0.0.1"), port);
		socket.output.writeString(text);
		var response = try socket.input.readAll().toString() catch (_:haxe.io.Eof) "";
		socket.close();
		var end = response.indexOf("\r\n\r\n");
		if (end < 0) throw "No HTTP response.";
		return {status: Std.parseInt(response.substring(9, 12)), body: response.substr(end + 4)};
	}

	static function call(entry:Dynamic, op:String, ?args:Dynamic):Dynamic {
		var response = request(entry, op, Json.stringify(args == null ? {} : args));
		if (response.status != 200) throw '$op answered ${response.status}: ${response.body}';
		return Json.parse(response.body);
	}

	static function send(entry:Dynamic, events:Array<Dynamic>):Void {
		call(entry, "input", {events: events});
	}

	static function extra(entry:Dynamic):Dynamic {
		return call(entry, "info").extra;
	}

	static function expectStatus(response:{status:Int, body:String}, status:Int, what:String):Void {
		check(response.status == status, '$what: expected HTTP $status, got ${response.status} ${response.body}');
	}

	static function expectError(entry:Dynamic, op:String, args:Dynamic, status:Int, code:String):Void {
		var response = request(entry, op, Json.stringify(args));
		check(response.status == status && Json.parse(response.body).error.code == code, '$op: expected $status $code, got ${response.status} ${response.body}');
	}

	static function freePort():Int {
		var socket = new Socket();
		socket.bind(new Host("127.0.0.1"), 0);
		var port = socket.host().port;
		socket.close();
		return port;
	}

	// Images

	static function png(base64:String):{width:Int, height:Int, pixels:Bytes} {
		var data = new format.png.Reader(new haxe.io.BytesInput(haxe.crypto.Base64.decode(base64))).read();
		var header = format.png.Tools.getHeader(data);
		return {width: header.width, height: header.height, pixels: format.png.Tools.extract32(data)};
	}

	static function checkColor(image:{width:Int, height:Int, pixels:Bytes}, x:Int, y:Int, rgb:Int, what:String):Void {
		var i = (y * image.width + x) * 4; // BGRA
		var b = image.pixels.get(i), g = image.pixels.get(i + 1), r = image.pixels.get(i + 2);
		var close = Math.abs(r - (rgb >> 16 & 0xFF)) <= 2 && Math.abs(g - (rgb >> 8 & 0xFF)) <= 2 && Math.abs(b - (rgb & 0xFF)) <= 2;
		check(close, '$what: pixel $x,$y is ${StringTools.hex((r << 16) | (g << 8) | b, 6)}, expected ${StringTools.hex(rgb, 6)}');
	}

	// Assertions

	static function check(condition:Bool, what:String):Void {
		if (!condition) throw what;
	}

	static function ok(what:String):Void {
		Sys.println("ok   " + what);
	}

	static function waitFor(test:Void->Bool, seconds:Float, what:String):Void {
		var deadline = Sys.time() + seconds;
		while (!test()) {
			if (Sys.time() > deadline) throw 'Timed out waiting for $what.';
			Sys.sleep(0.1);
		}
	}

	static function fatal(message:String):Void {
		Sys.println(message);
		Sys.exit(2);
	}
}

/** The MCP server, run.n, on stdin and stdout. */
class Mcp {
	public var server(default, null):Process;

	var id = 0;

	public function new(root:String) {
		server = new Process("neko", [Path.join([root, "run.n"]), "mcp"]);
	}

	public function rpc(method:String, ?params:Dynamic):Dynamic {
		var message:Dynamic = {jsonrpc: "2.0", id: ++id, method: method};
		if (params != null) message.params = params;
		server.stdin.writeString(Json.stringify(message) + "\n");
		server.stdin.flush();
		var response = Json.parse(server.stdout.readLine());
		if (response.id != id || response.jsonrpc != "2.0") throw 'Wrong response to $method: ' + Json.stringify(response);
		return response;
	}

	public function tool(name:String, ?args:Dynamic):{text:String, image:Null<String>, isError:Bool} {
		var result = rpc("tools/call", {name: name, arguments: args == null ? {} : args}).result;
		var content:Array<Dynamic> = result.content;
		var text = content.filter(c -> c.type == "text").map(c -> c.text).join("\n");
		var images = content.filter(c -> c.type == "image");
		return {text: text, image: images.length > 0 ? images[0].data : null, isError: result.isError == true};
	}

	public function close():Void {
		server.stdin.close();
		server.exitCode();
	}
}

/**
	A WebSocket client (RFC 6455) on a plain socket, so the tests need only the standard library
	and check crossbyte's server against a client that is not crossbyte's.
**/
class WebSocketClient {
	static inline var GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

	var socket:Socket;
	var id = 0;
	var queue:Array<Dynamic> = [];

	public function new(entry:Dynamic) {
		var opened = open(entry, [], "/lime-agent/v1");
		if (opened.status != 101) throw 'WebSocket upgrade answered ${opened.status}.';
		socket = opened.socket;
	}

	/** The status an upgrade with these headers gets. */
	public static function upgrade(entry:Dynamic, headers:Map<String, String>, path = "/lime-agent/v1"):Int {
		var opened = open(entry, headers, path);
		opened.socket.close();
		return opened.status;
	}

	static function open(entry:Dynamic, headers:Map<String, String>, path:String):{status:Int, socket:Socket} {
		var raw = Bytes.alloc(16);
		for (i in 0...16) raw.set(i, Std.random(256));
		var key = haxe.crypto.Base64.encode(raw);
		var all = ["Host" => '127.0.0.1:${entry.wsPort}', "Authorization" => 'Bearer ${entry.token}'];
		for (name => value in headers) all.set(name, value);
		var head = 'GET $path HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: $key\r\n';
		for (name => value in all) head += '$name: $value\r\n';
		var socket = new Socket();
		socket.setTimeout(15);
		socket.connect(new Host("127.0.0.1"), entry.wsPort);
		socket.output.writeString(head + "\r\n");
		socket.output.flush();
		// A byte at a time, so no frame that follows the head is read with it. The head is ASCII.
		var text = "";
		while (!StringTools.endsWith(text, "\r\n\r\n")) {
			var byte = try socket.input.readByte() catch (_:haxe.io.Eof) break;
			text += String.fromCharCode(byte);
		}
		var status = text.length >= 12 ? Std.parseInt(text.substring(9, 12)) : 0;
		if (status == 101) {
			var accept = haxe.crypto.Base64.encode(haxe.crypto.Sha1.make(Bytes.ofString(key + GUID)));
			if (text.indexOf("Sec-WebSocket-Accept: " + accept) < 0) throw "Wrong Sec-WebSocket-Accept: " + text;
		}
		return {status: status, socket: socket};
	}

	/** Sends an op and returns its answer; anything else that arrives first is kept for `next`. */
	public function call(op:String, ?args:Dynamic):Dynamic {
		var mine = ++id;
		send({id: mine, op: op, args: args == null ? {} : args});
		for (message in queue) if (message.id == mine) {
			queue.remove(message);
			return message;
		}
		while (true) {
			var message = Json.parse(receive());
			if (message.id == mine) return message;
			queue.push(message);
		}
	}

	public function send(message:Dynamic):Void {
		sendText(Json.stringify(message));
	}

	/** The next message: a kept one first, else the next to arrive. */
	public function next():Dynamic {
		return queue.length > 0 ? queue.shift() : Json.parse(receive());
	}

	public function sendText(text:String):Void {
		frame(0x1, Bytes.ofString(text));
	}

	public function close():Void {
		try frame(0x8, Bytes.ofString("")) catch (_:Dynamic) {}
		socket.close();
	}

	/** Clients mask every frame. */
	function frame(opcode:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		out.addByte(0x80 | opcode);
		if (payload.length < 126) out.addByte(0x80 | payload.length);
		else if (payload.length < 65536) {
			out.addByte(0x80 | 126);
			out.addByte(payload.length >> 8);
			out.addByte(payload.length & 0xFF);
		} else {
			out.addByte(0x80 | 127);
			for (_ in 0...4) out.addByte(0);
			for (shift in [24, 16, 8, 0]) out.addByte(payload.length >> shift & 0xFF);
		}
		var mask = [for (_ in 0...4) Std.random(256)];
		for (byte in mask) out.addByte(byte);
		for (i in 0...payload.length) out.addByte(payload.get(i) ^ mask[i % 4]);
		socket.output.write(out.getBytes());
		socket.output.flush();
	}

	/** One whole text message, answering pings and joining continuation frames. */
	function receive():String {
		var message = new BytesBuffer();
		while (true) {
			var first = socket.input.readByte(), second = socket.input.readByte();
			if (second & 0x80 != 0) throw "A server must not mask its frames.";
			var length = second & 0x7F;
			if (length == 126) length = socket.input.readByte() << 8 | socket.input.readByte();
			else if (length == 127) {
				length = 0;
				for (_ in 0...8) length = length << 8 | socket.input.readByte();
			}
			var payload = socket.input.read(length);
			switch first & 0x0F {
				case 0x8: throw "The app closed the WebSocket.";
				case 0x9: frame(0xA, payload);
				case 0xA:
				case 0x2: throw "The app sent a binary message.";
				default:
					message.add(payload);
					if (first & 0x80 != 0) return message.getBytes().toString();
			}
		}
	}
}
