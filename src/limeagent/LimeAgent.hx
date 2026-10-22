package limeagent;

import lime.graphics.Image;
import lime.ui.Window;

/**
	What an app can tell the agent. Nothing here is required. Every call is safe when the agent
	is not running, and costs nothing when it is compiled out (`-final` or `-D lime-agent-disable`).
**/
class LimeAgent {
	/** True when this launch serves the endpoint (`LIME_AGENT=1`). */
	public static var running(get, never):Bool;

	/** While true, screenshot, tree, input and commands are refused and `info` reports only that. */
	public static var sensitive:Void->Bool = () -> false;

	/** While true, `wait_idle` keeps waiting: loading, animating, waiting on the network. */
	public static var busy:Void->Bool = () -> false;

	/** Replaces reading the window framebuffer, for renderers `readPixels` cannot see. */
	public static var capture:Null<Window->Image> = null;

	static var infos:Array<{name:String, read:Void->Dynamic}> = [];
	static var commands:Map<String, Dynamic->Dynamic> = new Map();
	static var adapters:Array<Adapter> = [];
	static var stateHooks:Null<{snapshot:Void->String, restore:String->Void}>;

	/** An app-specific fact included in `info.extra`. Read only when asked, never while sensitive. */
	public static function addInfo(name:String, read:Void->Dynamic):Void {
		infos.push({name: name, read: read});
	}

	/** An app action agents may run by name. Needs input enabled, like any other act on the app. */
	public static function addCommand(name:String, run:Dynamic->Dynamic):Void {
		if (!~/^[a-z][a-z0-9_]{0,63}$/.match(name)) throw "Command names are lower_snake_case.";
		commands.set(name, run);
	}

	/** Consulted before the built-in adapters. */
	public static function addAdapter(adapter:Adapter):Void {
		adapters.push(adapter);
	}

	/** An error the app caught itself but an agent should see. */
	public static function reportError(error:Dynamic, ?stack:Array<haxe.CallStack.StackItem>):Void {
		#if lime_agent_active
		Agent.recordError(error, stack != null ? stack : haxe.CallStack.callStack().slice(1), false);
		#end
	}

	/** Phase 2 (hot reload) carries app state across a reload with these. Stored, not yet used. */
	public static function setStateHooks(snapshot:Void->String, restore:String->Void):Void {
		stateHooks = {snapshot: snapshot, restore: restore};
	}

	static function get_running():Bool {
		#if lime_agent_active
		return Agent.serving();
		#else
		return false;
		#end
	}
}
