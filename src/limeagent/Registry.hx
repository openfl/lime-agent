package limeagent;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** The per-user directory of running apps. Apps write it; the MCP server reads it. */
class Registry {
	public static inline var MAX_CRASHES = 10;

	public static function directory():String {
		var custom = Sys.getEnv("LIME_AGENT_REGISTRY");
		if (custom != null && custom != "") return Path.removeTrailingSlashes(custom);
		var home = Sys.getEnv(Sys.systemName() == "Windows" ? "USERPROFILE" : "HOME");
		return switch Sys.systemName() {
			case "Windows":
				var local = Sys.getEnv("LOCALAPPDATA");
				Path.join([local != null && local != "" ? local : Path.join([home, "AppData", "Local"]), "lime-agent", "apps"]);
			case "Mac": Path.join([home, "Library", "Application Support", "lime-agent", "apps"]);
			default:
				var runtime = Sys.getEnv("XDG_RUNTIME_DIR");
				runtime != null && runtime != "" ? Path.join([runtime, "lime-agent", "apps"]) : Path.join([home, ".local", "state", "lime-agent", "apps"]);
		}
	}

	/** Writes `<id>.json` atomically. Returns its path, or null when the directory cannot be made private. */
	public static function publish(id:String, entry:Dynamic):Null<String> {
		var dir = directory();
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		if (!makePrivate(dir, 0x1C0)) return null; // 0700
		var path = Path.join([dir, id + ".json"]);
		var temporary = path + ".tmp";
		File.saveContent(temporary, Json.stringify(entry));
		if (!makePrivate(temporary, 0x180)) { // 0600
			FileSystem.deleteFile(temporary);
			return null;
		}
		if (FileSystem.exists(path)) FileSystem.deleteFile(path);
		FileSystem.rename(temporary, path);
		return path;
	}

	public static function remove(path:Null<String>):Void {
		if (path != null) try FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}

	/** Crash records hold no token. */
	public static function writeCrash(id:String, record:Dynamic):Void {
		var dir = directory();
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		File.saveContent(Path.join([dir, id + ".crash.json"]), Json.stringify(record));
	}

	public static function entries():Array<{path:String, entry:Dynamic}> {
		return read(".json", name -> !StringTools.endsWith(name, ".crash.json"));
	}

	public static function crashes():Array<{path:String, entry:Dynamic}> {
		var all = read(".crash.json", _ -> true);
		all.sort((a, b) -> Reflect.compare(Std.string(b.entry.time), Std.string(a.entry.time)));
		for (old in all.slice(MAX_CRASHES)) remove(old.path);
		return all.slice(0, MAX_CRASHES);
	}

	static function read(suffix:String, accept:String->Bool):Array<{path:String, entry:Dynamic}> {
		var dir = directory(), result = [];
		if (!FileSystem.exists(dir)) return result;
		for (name in FileSystem.readDirectory(dir)) {
			if (!StringTools.endsWith(name, suffix) || !accept(name)) continue;
			var path = Path.join([dir, name]);
			try result.push({path: path, entry: Json.parse(File.getContent(path))}) catch (_:Dynamic) {}
		}
		return result;
	}

	static function makePrivate(path:String, mode:Int):Bool {
		if (Sys.systemName() == "Windows") return true;
		Native.chmod(path, mode);
		return FileSystem.stat(path).mode & 0x3F == 0; // no group or other bits
	}
}
