package limeagent.cli;

import haxe.Json;
import limeagent.Registry;
import limeagent.cli.AppClient;

/**
	The MCP stdio server: JSON-RPC 2.0, one message per line on stdin and stdout.
	It reads the registry and talks only to the loopback ports listed there.
**/
class McpServer {
	public static inline var VERSION = "0.1.0";
	static var PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];

	static var INSTRUCTIONS = "Inspect and drive running Lime/OpenFL apps that were launched with LIME_AGENT=1. "
		+ "Start with list_apps. Coordinates for click and scroll are pixels in the screenshot image. "
		+ "After input, call wait_idle before taking a screenshot. Input needs the app to be launched with LIME_AGENT_INPUT=1.";

	public static function run():Void {
		var input = Sys.stdin();
		while (true) {
			var line = try input.readLine() catch (_:haxe.io.Eof) break;
			if (StringTools.trim(line) == "") continue;
			var message:Dynamic = try Json.parse(line) catch (_:Dynamic) {
				send(Json.stringify({jsonrpc: "2.0", id: null, error: {code: -32700, message: "Parse error"}}));
				continue;
			};
			try handle(message) catch (error:Dynamic) {
				if (message.id != null) send(Json.stringify({jsonrpc: "2.0", id: message.id, error: {code: -32603, message: Std.string(error)}}));
			}
		}
	}

	static function handle(message:Dynamic):Void {
		var id:Dynamic = message.id;
		var method:String = message.method;
		if (method == null) return; // a response to something we never send
		var params:Dynamic = message.params == null ? {} : message.params;
		switch method {
			case "initialize":
				var requested:String = params.protocolVersion;
				reply(id, {
					protocolVersion: PROTOCOLS.indexOf(requested) >= 0 ? requested : PROTOCOLS[0],
					capabilities: {tools: {listChanged: false}},
					serverInfo: {name: "lime-agent", version: VERSION},
					instructions: INSTRUCTIONS
				});
			case "ping":
				reply(id, {});
			case "tools/list":
				reply(id, {tools: Tools.definitions()});
			case "tools/call":
				var name:String = params.name;
				var args:Dynamic = params.arguments;
				respond(id, Tools.call(name, args == null ? {} : args));
			default:
				if (id != null) send(Json.stringify({jsonrpc: "2.0", id: id, error: {code: -32601, message: 'Method not found: $method'}}));
		}
	}

	static var BASE64 = ~/^[A-Za-z0-9+\/=]*$/;

	/** Written by hand so a multi-megabyte screenshot is not walked character by character by the JSON printer. */
	static function respond(id:Dynamic, result:Tools.ToolResult):Void {
		var line = new StringBuf();
		line.add('{"jsonrpc":"2.0","id":' + Json.stringify(id) + ',"result":{"content":[');
		if (result.image != null && BASE64.match(result.image)) line.add('{"type":"image","mimeType":"image/png","data":"' + result.image + '"},');
		line.add(Json.stringify({type: "text", text: result.text}));
		line.add(']' + (result.isError == true ? ',"isError":true' : '') + '}}');
		send(line.toString());
	}

	public static function reply(id:Dynamic, result:Dynamic):Void {
		send(Json.stringify({jsonrpc: "2.0", id: id, result: result}));
	}

	public static function send(line:String):Void {
		var out = Sys.stdout();
		out.writeString(line + "\n");
		out.flush();
	}
}
