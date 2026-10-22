package limeagent.cli;

import haxe.Json;
import limeagent.Registry;
import limeagent.cli.AppClient;

typedef ToolResult = {text:String, ?image:String, ?isError:Bool};

/** A live app: its registry entry, a client for it, and its latest `info`. */
typedef LiveApp = {client:AppClient, info:Dynamic};

/** The MCP tools. Each maps to one or two endpoint calls and answers in short plain text. */
class Tools {
	static var APP = {type: "string", description: "The app's pid or part of its name. Optional when exactly one app is running."};

	public static function definitions():Array<Dynamic> {
		return [
			tool("list_apps", "List running Lime apps that have lime-agent enabled, with their window size and whether input is allowed, plus recent crashes.", {}, true),
			tool("screenshot", "Capture the app's window as a PNG. Coordinates for click and scroll are pixels in this image.", {app: APP}, true),
			tool("ui_tree", "The app's UI as an outline: one control per line with its kind, name, text and bounds [x,y width x height] in screenshot pixels.",
				{app: APP, maxNodes: {type: "integer", description: "At most this many controls (default 400)."}}, true),
			tool("click", "Click at a point in screenshot pixels, through the app's own mouse events.", {
				app: APP,
				x: {type: "number"},
				y: {type: "number"},
				button: {type: "string", "enum": ["left", "right", "middle"]},
				double: {type: "boolean", description: "Double-click."}
			}, false, ["x", "y"]),
			tool("type", "Type text into the focused control, as committed text input.", {app: APP, text: {type: "string"}}, false, ["text"]),
			tool("key", "Press a key, with optional modifiers. Keys: letters, digits, punctuation, enter, tab, escape, backspace, delete, space, arrows (left, right, up, down), home, end, pageup, pagedown, insert, f1-f12.", {
				app: APP,
				key: {type: "string"},
				modifiers: {type: "array", items: {type: "string", "enum": ["ctrl", "shift", "alt", "meta"]}},
				action: {type: "string", "enum": ["press", "down", "up"], description: "press (default) sends down then up."}
			}, false, ["key"]),
			tool("scroll", "Scroll with the mouse wheel. Positive dy scrolls down, positive dx scrolls right; units are wheel steps.", {
				app: APP,
				dx: {type: "number"},
				dy: {type: "number"},
				x: {type: "number", description: "Optional point to scroll at, in screenshot pixels."},
				y: {type: "number"}
			}, false),
			tool("logs", "Recent log lines (trace output and Lime log messages). Pass the returned next value as since to read only newer lines.", {
				app: APP,
				since: {type: "integer"},
				limit: {type: "integer", description: "Default 100."},
				minLevel: {type: "string", "enum": ["verbose", "debug", "trace", "info", "warn", "error"]}
			}, true),
			tool("errors", "Errors with stack traces: uncaught exceptions, Lime errors and errors the app reported. For an app that crashed, its crash record.", {
				app: APP,
				since: {type: "integer"}
			}, true),
			tool("wait_idle", "Wait until the app has handled queued input and is not busy, for a few frames in a row. Use after input, before a screenshot.", {
				app: APP,
				timeoutMs: {type: "integer", description: "Default 5000, at most 30000."},
				quietFrames: {type: "integer", description: "Default 3."}
			}, true)
		];
	}

	static function tool(name:String, description:String, properties:Dynamic, readOnly:Bool, ?required:Array<String>):Dynamic {
		var schema:Dynamic = {type: "object", properties: properties, additionalProperties: false};
		if (required != null) schema.required = required;
		return {name: name, description: description, inputSchema: schema, annotations: {readOnlyHint: readOnly, openWorldHint: false}};
	}

	public static function call(name:String, args:Dynamic):ToolResult {
		try {
			return switch name {
				case "list_apps": listApps();
				case "screenshot": screenshot(args);
				case "ui_tree": uiTree(args);
				case "click":
					var x = number(args.x, "x"), y = number(args.y, "y");
					var button = args.button == null ? "left" : args.button;
					var press:Array<Dynamic> = [{type: "mouse_down", x: x, y: y, button: button}, {type: "mouse_up", x: x, y: y, button: button}];
					var move:Dynamic = {type: "mouse_move", x: x, y: y};
					var events:Array<Dynamic> = [move].concat(press);
					if (args.double == true) events = events.concat(press);
					input(args, events, '${args.double == true ? "Double-clicked" : "Clicked"} $button at $x,$y.');
				case "type":
					if (!Std.isOfType(args.text, String)) throw "text is required.";
					input(args, [{type: "text", text: args.text}], 'Typed ${(args.text : String).length} characters.');
				case "key":
					var action = args.action == null ? "press" : args.action;
					var down = {type: "key_down", key: args.key, modifiers: args.modifiers}, up = {type: "key_up", key: args.key, modifiers: args.modifiers};
					var events:Array<Dynamic> = switch action {
						case "press": [down, up];
						case "down": [down];
						case "up": [up];
						default: throw "action must be press, down or up.";
					};
					var combo = (args.modifiers == null ? [] : (args.modifiers : Array<String>)).concat([args.key]).join("+");
					input(args, events, 'Key $action: $combo.');
				case "scroll":
					var event:Dynamic = {type: "wheel", dx: args.dx == null ? 0 : number(args.dx, "dx"), dy: args.dy == null ? 0 : number(args.dy, "dy")};
					if (args.x != null || args.y != null) {
						event.x = number(args.x, "x");
						event.y = number(args.y, "y");
					}
					input(args, [event], 'Scrolled ${event.dx},${event.dy}.');
				case "logs": logs(args);
				case "errors": errors(args);
				case "wait_idle": waitIdle(args);
				default: {text: 'Unknown tool "$name".', isError: true};
			}
		} catch (error:AppError) {
			return {text: explain(error), isError: true};
		} catch (error:Unreachable) {
			return {text: error.message, isError: true};
		} catch (error:Dynamic) {
			return {text: Std.string(error), isError: true};
		}
	}

	// Apps

	/** Every registered app that answers; entries whose app is gone are removed. */
	public static function liveApps():Array<LiveApp> {
		var result = [];
		for (item in Registry.entries()) {
			var client = new AppClient(item.entry);
			try {
				result.push({client: client, info: client.call("info", null, 3)});
			} catch (error:Unreachable) {
				if (error.refused) Registry.remove(item.path);
				else result.push({client: client, info: null});
			} catch (error:AppError) {
				// Another process took the port: this entry's app is gone.
				if (error.status == 403) Registry.remove(item.path);
			}
		}
		return result;
	}

	static function resolve(selector:Dynamic):LiveApp {
		var apps = liveApps();
		if (selector != null) {
			var wanted = Std.string(selector).toLowerCase();
			apps = apps.filter(app -> Std.string(app.client.entry.pid) == wanted || Std.string(app.client.entry.name).toLowerCase().indexOf(wanted) >= 0
				|| Std.string(app.client.entry.title).toLowerCase().indexOf(wanted) >= 0);
		}
		if (apps.length == 1) {
			if (apps[0].info == null) throw 'App ${describe(apps[0].client.entry)} is not responding; its frame loop may be stuck.';
			return apps[0];
		}
		if (apps.length == 0) {
			var crash = recentCrash(selector);
			throw (selector == null ? "No Lime app with lime-agent is running." : 'No running app matches "$selector".')
				+ " Launch a build that includes the lime-agent haxelib with LIME_AGENT=1 (and LIME_AGENT_INPUT=1 to allow input)."
				+ (crash == null ? "" : ' The most recent crash: ${crash.name} (pid ${crash.pid}): ${crash.message}. Call errors for its stack.');
		}
		throw "Several apps are running; pass app as one of: " + [for (app in apps) describe(app.client.entry)].join("; ");
	}

	static function describe(entry:Dynamic):String {
		return 'pid ${entry.pid} "${entry.name}"';
	}

	static function recentCrash(selector:Dynamic):Dynamic {
		for (crash in Registry.crashes()) {
			var entry = crash.entry;
			if (selector == null || Std.string(entry.pid) == Std.string(selector)
				|| Std.string(entry.name).toLowerCase().indexOf(Std.string(selector).toLowerCase()) >= 0) return entry;
		}
		return null;
	}

	// Tools

	static function listApps():ToolResult {
		var lines = [];
		for (app in liveApps()) {
			var entry = app.client.entry, info = app.info;
			if (info == null) {
				lines.push('${describe(entry)}: not responding');
				continue;
			}
			var title = info.app.title != entry.name && info.app.title != null && info.app.title != "" ? ' window "${info.app.title}"' : "";
			var line = '${describe(entry)}$title: ${info.window.viewWidth}x${info.window.viewHeight} pixels, input ${info.input ? "on" : "off"}';
			if (info.sensitive) line += ", sensitive view open";
			var frameworks:Array<String> = info.frameworks;
			line += ', Lime ${info.lime}' + (frameworks.length > 0 ? ", " + frameworks.join(", ") : "");
			if (info.lastError > 0) line += ', ${info.lastError} error(s) so far';
			var commands = (info.capabilities : Array<String>).filter(c -> StringTools.startsWith(c, "command:"));
			if (commands.length > 0) line += ", app commands: " + commands.map(c -> c.substr(8)).join(", ");
			lines.push(line);
		}
		if (lines.length == 0) lines.push("No Lime app with lime-agent is running. Launch one with LIME_AGENT=1 (and LIME_AGENT_INPUT=1 to allow input).");
		var crashes = Registry.crashes().slice(0, 3);
		if (crashes.length > 0) {
			lines.push("Recent crashes:");
			for (crash in crashes) lines.push('  ${describe(crash.entry)} at ${Date.fromTime(crash.entry.time).toString()}: ${crash.entry.message}');
		}
		return {text: lines.join("\n")};
	}

	static function screenshot(args:Dynamic):ToolResult {
		var app = resolve(args.app);
		var body = app.client.raw("screenshot", null, 10);
		// The PNG is the bulk of the answer; take it out without parsing megabytes of JSON.
		var key = '"pngBase64":"';
		var start = body.indexOf(key);
		if (start < 0) throw "The app returned no image.";
		start += key.length;
		var end = body.indexOf('"', start);
		var rest = body.substr(0, start) + body.substr(end);
		var width = ~/"width":([0-9]+)/, height = ~/"height":([0-9]+)/;
		var size = width.match(rest) && height.match(rest) ? '${width.matched(1)}x${height.matched(1)} pixels' : "Screenshot";
		return {image: body.substring(start, end), text: '$size from ${describe(app.client.entry)}. Click and scroll coordinates use this grid.'};
	}

	static function uiTree(args:Dynamic):ToolResult {
		var app = resolve(args.app);
		var tree = app.client.call("tree", args.maxNodes == null ? {} : {maxNodes: args.maxNodes});
		var lines = ['UI of ${describe(app.client.entry)} from the ${tree.adapter} adapter, ${tree.width}x${tree.height} pixels (same grid as screenshot):'];
		function walk(nodes:Array<Dynamic>, depth:Int) {
			for (node in nodes) {
				var line = StringTools.lpad("", " ", depth * 2) + node.kind;
				if (node.name != null) line += " #" + node.name;
				if (node.text != null) {
					var text:String = StringTools.replace(StringTools.replace(node.text, "\r", ""), "\n", "\\n");
					line += ' "' + (text.length > 300 ? text.substr(0, 300) + "..." : text) + '"';
				}
				line += ' [${node.x},${node.y} ${node.width}x${node.height}]';
				if (node.enabled == false) line += " disabled";
				if (node.focused == true) line += " focused";
				lines.push(line);
				if (node.children != null) walk(node.children, depth + 1);
			}
		}
		walk(tree.nodes, 0);
		if ((tree.nodes : Array<Dynamic>).length == 0) lines.push("(no controls)");
		if (tree.truncated) lines.push("(truncated; pass a larger maxNodes for more)");
		return {text: lines.join("\n")};
	}

	static function input(args:Dynamic, events:Array<Dynamic>, done:String):ToolResult {
		var app = resolve(args.app);
		app.client.call("input", {events: events}, 15);
		return {text: done};
	}

	static function logs(args:Dynamic):ToolResult {
		var app = resolve(args.app);
		var request:Dynamic = {};
		if (args.since != null) request.since = args.since;
		if (args.limit != null) request.limit = args.limit;
		if (args.minLevel != null) request.minLevel = args.minLevel;
		var result = app.client.call("logs", request);
		var lines = [for (entry in (result.entries : Array<Dynamic>))
			'#${entry.seq} [${entry.level}] ${entry.message}' + (entry.source == null ? "" : ' (${entry.source})')];
		if (lines.length == 0) lines.push("No log lines.");
		if (result.dropped > 0) lines.unshift('(${result.dropped} older lines were dropped from the ring)');
		lines.push('next: ${result.next}');
		return {text: lines.join("\n")};
	}

	static function errors(args:Dynamic):ToolResult {
		var app = try resolve(args.app) catch (error:Dynamic) {
			var crash = recentCrash(args.app);
			if (crash == null) throw error;
			return {text: 'The app is not running. Its crash record:\n' + formatError({seq: 0, fatal: true, message: crash.message, stack: crash.stack})
				+ "\nLast log lines:\n" + (crash.logs : Array<String>).join("\n")};
		};
		var result = app.client.call("errors", args.since == null ? {} : {since: args.since});
		var lines = [for (entry in (result.entries : Array<Dynamic>)) formatError(entry)];
		if (lines.length == 0) lines.push("No errors.");
		lines.push('next: ${result.next}');
		return {text: lines.join("\n")};
	}

	static function formatError(entry:Dynamic):String {
		var stack:Array<String> = entry.stack;
		return '#${entry.seq}${entry.fatal ? " fatal" : ""}: ${entry.message}' + (stack.length == 0 ? "" : "\n" + stack.map(f -> "    at " + f).join("\n"));
	}

	static function waitIdle(args:Dynamic):ToolResult {
		var app = resolve(args.app);
		var request:Dynamic = {};
		if (args.timeoutMs != null) request.timeoutMs = args.timeoutMs;
		if (args.quietFrames != null) request.quietFrames = args.quietFrames;
		var timeout:Int = args.timeoutMs == null ? 5000 : args.timeoutMs;
		var result = app.client.call("wait_idle", request, timeout / 1000 + 5);
		return result.idle ? {text: 'Idle after ${result.waitedMs} ms.'} : {text: 'Not idle after ${result.waitedMs} ms (${result.reason}).', isError: true};
	}

	static function explain(error:AppError):String {
		return switch error.code {
			case "input_disabled": "Input is off for this app. Relaunch it with LIME_AGENT_INPUT=1 to allow click, type, key and scroll.";
			case "sensitive": "The app is showing something sensitive, such as a password or key entry. Screenshots, the UI tree and input are blocked until it closes.";
			case "unauthorized": "The app refused the registry token; it may have restarted. Call list_apps.";
			default: error.message;
		}
	}

	static function number(value:Dynamic, name:String):Float {
		if (!Std.isOfType(value, Float) && !Std.isOfType(value, Int)) throw '$name must be a number.';
		return value;
	}
}
