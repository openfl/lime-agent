package limeagent.cli;

/** `haxelib run lime-agent <command>`. */
class Run {
	static function main():Void {
		var args = Sys.args();
		// haxelib run appends the caller's working directory.
		if (Sys.getEnv("HAXELIB_RUN") == "1" && args.length > 0) args.pop();
		switch args.length == 0 ? "help" : args[0] {
			case "mcp":
				McpServer.run();
			case "list":
				Sys.println(Tools.call("list_apps", {}).text);
			case "registry":
				Sys.println(limeagent.Registry.directory());
			case "version":
				Sys.println(McpServer.VERSION);
			default:
				Sys.println("lime-agent " + McpServer.VERSION + "\n\n"
					+ "  haxelib run lime-agent mcp        MCP server on stdin and stdout, for Claude Code, Codex, Cursor\n"
					+ "  haxelib run lime-agent list       Running apps with lime-agent enabled, and recent crashes\n"
					+ "  haxelib run lime-agent registry   Where running apps register\n\n"
					+ "Enable an app: add <haxelib name=\"lime-agent\" /> and launch with LIME_AGENT=1 (LIME_AGENT_INPUT=1 for input).");
		}
	}
}
