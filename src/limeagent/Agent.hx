package limeagent;

#if lime_agent_active
import haxe.CallStack;
import haxe.Json;
import haxe.crypto.Base64;
import lime.app.Application;
import lime.graphics.Image;
import lime.graphics.ImageFileFormat;
import lime.graphics.RenderContext;
import lime.ui.MouseWheelMode;
import lime.ui.Window;
import limeagent.Adapter;
import limeagent.http.LoopbackServer;

typedef LogEntry = {seq:Int, time:Float, level:String, message:String, ?source:String};
typedef ErrorEntry = {seq:Int, time:Float, message:String, stack:Array<String>, fatal:Bool};

private class AgentError {
	public var status:Int;
	public var code:String;
	public var message:String;

	public function new(status:Int, code:String, message:String) {
		this.status = status;
		this.code = code;
		this.message = message;
	}
}

/**
	The in-app side of lime-agent: a loopback endpoint pumped from `Application.onUpdate`.
	Attached by the init macro when the first Application is constructed; does nothing unless `LIME_AGENT=1`.
**/
@:access(limeagent.LimeAgent)
class Agent {
	public static inline var PROTOCOL = 1;
	static inline var PREFIX = "/lime-agent/v1/";
	static var LEVELS = ["verbose", "debug", "trace", "info", "warn", "error"];
	static var EVENTS = ["mouse_move", "mouse_down", "mouse_up", "wheel", "key_down", "key_up", "text"];

	public static var logs(default, null) = new Journal<LogEntry>(1000);
	public static var errors(default, null) = new Journal<ErrorEntry>(100);

	static var app:Application;
	static var window:Window;
	static var server:LoopbackServer;
	static var token:String;
	static var id:String;
	static var input = false;
	static var failed = false;
	static var crashed = false;
	static var frame = 0;
	static var registryPath:Null<String>;
	static var adapters:Array<Adapter> = [];
	static var captures:Array<{request:Request, deadline:Float}> = [];
	static var inputs:Array<{request:Request, events:Array<Dynamic>, next:Int, settle:Int}> = [];
	static var waiters:Array<{request:Request, deadline:Float, quiet:Int, idleFrom:Int, started:Float}> = [];
	static var lastErrorValue:Dynamic;
	static var lastError:Null<ErrorEntry>;

	public static function attach(application:Application):Void {
		if (app != null || !requested()) return;
		app = application;
		var previous = haxe.Log.trace;
		haxe.Log.trace = (value:Dynamic, ?infos:haxe.PosInfos) -> {
			var text = Std.string(value);
			if (infos != null && infos.customParams != null) text += ", " + infos.customParams.map(Std.string).join(", ");
			log("trace", text, infos == null ? null : infos.fileName + ":" + infos.lineNumber);
			previous(value, infos);
		};
		application.onUpdate.add(update, false, -100000);
		application.onExit.add(_ -> stop(), false, -100000);
	}

	public static function serving():Bool {
		return server != null;
	}

	static function requested():Bool {
		#if lime_agent_autostart
		return true;
		#else
		return Sys.getEnv("LIME_AGENT") == "1";
		#end
	}

	static function start(target:Window):Void {
		window = target;
		input = #if lime_agent_input true #else Sys.getEnv("LIME_AGENT_INPUT") == "1" #end;
		var envToken = Sys.getEnv("LIME_AGENT_TOKEN"), envPort = Sys.getEnv("LIME_AGENT_PORT");
		if (envToken == "") envToken = null;
		if (envToken != null && envToken.length < 24) throw "LIME_AGENT_TOKEN must be at least 24 characters.";
		var port = 0;
		if (envPort != null && envPort != "") {
			var parsed = Std.parseInt(envPort);
			if (parsed == null || parsed < 1024 || parsed > 65535) throw "LIME_AGENT_PORT must be between 1024 and 65535.";
			port = parsed;
		}
		token = envToken != null ? envToken : Native.secureRandom(32).toHex();
		server = new LoopbackServer(port);
		adapters = LimeAgent.adapters.concat(builtInAdapters());
		for (adapter in adapters) try adapter.install() catch (error:Dynamic) log("warn", 'lime-agent: ${adapter.name} hooks failed: $error');
		window.onRender.add(render, false, -1000000);
		var pid = Native.pid();
		id = pid > 0 ? Std.string(pid) : Native.secureRandom(8).toHex();
		registryPath = try Registry.publish(id, {
			protocol: PROTOCOL, pid: pid, name: appName(), title: window.title, port: server.port, token: token,
			started: Date.now().getTime(), capabilities: capabilities(), lime: limeVersion(), frameworks: frameworks(), exe: Sys.programPath()
		}) catch (error:Dynamic) {
			log("warn", 'lime-agent: registry not written: $error');
			null;
		};
		var line = 'lime-agent listening on 127.0.0.1:${server.port}, input ${input ? "on" : "off"}'
			+ (registryPath == null ? "; not registered because the registry directory is not private" : "");
		log("info", line);
		Sys.println("[" + line + "]");
	}

	static function builtInAdapters():Array<Adapter> {
		var list:Array<Adapter> = [];
		#if graphaxe
		list.push(new limeagent.adapters.GraphaxeAdapter());
		#end
		#if feathersui
		list.push(new limeagent.adapters.FeathersAdapter());
		#elseif openfl
		list.push(new limeagent.adapters.OpenFLAdapter());
		#end
		return list;
	}

	static function stop():Void {
		Registry.remove(registryPath);
		registryPath = null;
		if (server != null) try server.close() catch (_:Dynamic) {}
		server = null;
		failed = true;
	}

	static function update(_:Int):Void {
		if (failed) return;
		if (server == null) {
			if (app.window == null) return;
			try start(app.window) catch (error:Dynamic) {
				failed = true;
				log("error", 'lime-agent not started: $error');
				Sys.println('[lime-agent not started: $error]');
			}
			return;
		}
		frame++;
		server.pump(handle);
		// Not caught: an exception the app throws while handling input is the app's own uncaught error.
		pumpInput();
		pumpWaiters();
		pumpCaptures();
	}

	// Requests

	static function handle(request:Request):Void {
		try {
			if (!authorized(request)) throw new AgentError(403, "unauthorized", "Authorization required.");
			if (request.method != "POST") throw new AgentError(405, "bad_request", "Use POST.");
			if (!StringTools.startsWith(request.path, PREFIX)) throw new AgentError(404, "unknown_op", 'Unknown endpoint; this app speaks protocol $PROTOCOL at $PREFIX.');
			var args:Dynamic = request.body == "" ? {} : Json.parse(request.body);
			if (args == null || Type.typeof(args) != TObject) throw "The body must be a JSON object.";
			dispatch(request.path.substr(PREFIX.length), args, request);
		} catch (error:AgentError) {
			fail(request, error);
		} catch (error:Dynamic) {
			fail(request, new AgentError(400, "bad_request", Std.string(error)));
		}
	}

	/** Loopback host, no browser origin, JSON only, and the bearer token. */
	static function authorized(request:Request):Bool {
		if (request.hasHeader("origin")) return false;
		var host = request.header("host");
		if (host != '127.0.0.1:${server.port}' && host != 'localhost:${server.port}') return false;
		var type = request.header("content-type");
		if (type == null || !StringTools.startsWith(type.toLowerCase(), "application/json")) return false;
		var auth = request.header("authorization");
		return auth != null && constantEquals(auth, "Bearer " + token);
	}

	static function dispatch(op:String, args:Dynamic, request:Request):Void {
		switch op {
			case "info":
				ok(request, info());
			case "screenshot":
				requireView();
				var image = immediateCapture();
				if (image != null) ok(request, encode(image));
				else {
					captures.push({request: request, deadline: Sys.time() + 3});
					requestRender();
				}
			case "tree":
				requireView();
				ok(request, tree(integer(args.maxNodes, 400, 1, 5000), args.includeHidden == true));
			case "input":
				requireInput();
				requireView();
				inputs.push({request: request, events: parseEvents(args.events), next: 0, settle: -1});
			case "logs":
				var minimum = args.minLevel == null ? 0 : LEVELS.indexOf(args.minLevel);
				if (minimum < 0) throw 'minLevel must be one of ${LEVELS.join(", ")}.';
				ok(request, logs.since(integer(args.since, 0, 0, null), integer(args.limit, 100, 1, 1000), entry -> LEVELS.indexOf(entry.level) >= minimum));
			case "errors":
				ok(request, errors.since(integer(args.since, 0, 0, null), integer(args.limit, 20, 1, 100)));
			case "wait_idle":
				var timeout = integer(args.timeoutMs, 5000, 0, 30000);
				waiters.push({request: request, deadline: Sys.time() + timeout / 1000, quiet: integer(args.quietFrames, 3, 1, 600), idleFrom: -1, started: Sys.time()});
			case "command":
				requireInput();
				requireView();
				var run = LimeAgent.commands.get(Std.string(args.name));
				if (run == null) throw new AgentError(404, "unknown_op", 'This app has no command "${args.name}".');
				ok(request, {result: run(args.args)});
			default:
				throw new AgentError(404, "unknown_op", 'Unknown op "$op". Check capabilities in info.');
		}
	}

	static function info():Dynamic {
		var sensitive = isSensitive();
		var view = viewSize();
		var result:Dynamic = {
			protocol: {version: PROTOCOL, min: PROTOCOL},
			app: {name: appName(), version: app.meta.get("version"), pid: Native.pid(), title: window.title},
			lime: limeVersion(),
			frameworks: frameworks(),
			capabilities: capabilities(),
			window: {width: window.width, height: window.height, scale: window.scale, viewWidth: view.width, viewHeight: view.height},
			frame: frame,
			sensitive: sensitive,
			busy: isBusy(),
			input: input,
			lastLog: logs.last,
			lastError: errors.last
		};
		if (!sensitive && LimeAgent.infos.length > 0) {
			var extra = {};
			for (item in LimeAgent.infos) Reflect.setField(extra, item.name, try item.read() catch (error:Dynamic) 'error: $error');
			result.extra = extra;
		}
		return result;
	}

	static function capabilities():Array<String> {
		var list = ["info", "screenshot", "logs", "errors", "wait_idle"];
		if (adapters.length > 0) list.push("tree");
		if (input) {
			list.push("input");
			for (name in LimeAgent.commands.keys()) list.push("command:" + name);
		}
		return list;
	}

	static function requireView():Void {
		if (window == null || app.window == null) throw new AgentError(503, "unavailable", "The app has no window.");
		if (isSensitive()) throw new AgentError(423, "sensitive", "The app is showing something sensitive; inspection and input are blocked.");
	}

	static function requireInput():Void {
		if (!input) throw new AgentError(403, "input_disabled", "Input was not enabled for this launch (LIME_AGENT_INPUT=1).");
	}

	static function isSensitive():Bool {
		return try LimeAgent.sensitive() catch (_:Dynamic) true;
	}

	static function isBusy():Bool {
		return try LimeAgent.busy() catch (_:Dynamic) false;
	}

	// View and screenshots

	static function activeAdapters():Array<Adapter> {
		return [for (adapter in adapters) if (try adapter.active() catch (_:Dynamic) false) adapter];
	}

	/** The coordinate space of screenshots, trees and input. */
	static function viewSize():{width:Int, height:Int} {
		for (adapter in activeAdapters()) {
			var size = adapter.viewSize();
			if (size != null && size.width > 0 && size.height > 0) return size;
		}
		return {width: Math.round(window.width * window.scale), height: Math.round(window.height * window.scale)};
	}

	static function immediateCapture():Null<Image> {
		if (LimeAgent.capture != null) return LimeAgent.capture(window);
		for (adapter in activeAdapters()) {
			var image = adapter.capture();
			if (image != null) return image;
		}
		return null;
	}

	static function requestRender():Void {
		for (adapter in activeAdapters()) try adapter.requestRender() catch (_:Dynamic) {}
	}

	/** Lowest priority on `window.onRender`: the frame is drawn and not yet presented. */
	static function render(_:RenderContext):Void {
		if (captures.length == 0) return;
		var pending = captures;
		captures = [];
		var result:Dynamic = null, failure:AgentError = null;
		try {
			requireView();
			var image = readFramebuffer();
			if (image == null) throw new AgentError(503, "unavailable", "This window's renderer cannot be read back; set LimeAgent.capture.");
			result = encode(image);
		} catch (error:AgentError) {
			failure = error;
		} catch (error:Dynamic) {
			failure = new AgentError(500, "internal", Std.string(error));
		}
		for (item in pending) failure != null ? fail(item.request, failure) : ok(item.request, result);
	}

	static function readFramebuffer():Null<Image> {
		var image:Image;
		switch window.context.type {
			case OPENGL, OPENGLES, WEBGL:
				// The app may have left an offscreen framebuffer bound; read the window's own.
				var gl = window.context.webgl;
				var bound = gl.getParameter(gl.FRAMEBUFFER_BINDING);
				gl.bindFramebuffer(gl.FRAMEBUFFER, null);
				image = window.readPixels();
				gl.bindFramebuffer(gl.FRAMEBUFFER, bound);
			default:
				image = window.readPixels();
		}
		if (image == null) return null;
		// Framebuffer alpha is whatever the last clear left; the window itself is opaque.
		var data = image.buffer.data;
		var i = 3;
		while (i < data.length) {
			data[i] = 255;
			i += 4;
		}
		return image;
	}

	static function pumpCaptures():Void {
		if (captures.length == 0) return;
		requestRender();
		var now = Sys.time();
		for (item in captures.copy()) if (now > item.deadline) {
			captures.remove(item);
			fail(item.request, new AgentError(503, "unavailable", "The app did not render a frame within 3 seconds."));
		}
	}

	static function encode(image:Image):Dynamic {
		var view = viewSize();
		if (image.width != view.width || image.height != view.height) image.resize(view.width, view.height);
		var png = image.encode(ImageFileFormat.PNG);
		if (png == null) throw new AgentError(500, "internal", "PNG encoding failed.");
		return {pngBase64: Base64.encode(png), width: image.width, height: image.height};
	}

	static function tree(maxNodes:Int, includeHidden:Bool):Dynamic {
		var options = new TreeOptions(maxNodes, includeHidden);
		for (adapter in activeAdapters()) {
			var nodes = adapter.tree(options);
			if (nodes != null) {
				var view = viewSize();
				return {adapter: adapter.name, width: view.width, height: view.height, truncated: options.truncated, nodes: nodes};
			}
		}
		throw new AgentError(501, "unsupported", "No UI tree adapter is active. Plain Lime apps can add one with LimeAgent.addAdapter.");
	}

	// Input

	static function parseEvents(list:Dynamic):Array<Dynamic> {
		if (!Std.isOfType(list, Array)) throw "events must be an array.";
		var events:Array<Dynamic> = list;
		if (events.length == 0 || events.length > 200) throw "Send between 1 and 200 events.";
		var view = viewSize();
		var result:Array<Dynamic> = [];
		for (event in events) {
			var type = Std.string(event.type);
			if (EVENTS.indexOf(type) < 0) throw 'Event type must be one of ${EVENTS.join(", ")}.';
			switch type {
				case "mouse_move", "mouse_down", "mouse_up":
					var x = number(event.x), y = number(event.y);
					if (x < 0 || y < 0 || x >= view.width || y >= view.height) throw 'Point $x,$y is outside the ${view.width}x${view.height} view.';
					var button = switch event.button {
						case null, "left": 0;
						case "middle": 1;
						case "right": 2;
						default: throw "button must be left, middle or right.";
					};
					result.push({type: type, x: x, y: y, button: button});
				case "wheel":
					if (event.x != null || event.y != null) result.push(parseEvents([{type: "mouse_move", x: event.x, y: event.y}])[0]);
					var dx = event.dx == null ? 0.0 : number(event.dx), dy = event.dy == null ? 0.0 : number(event.dy);
					if (Math.abs(dx) > 100 || Math.abs(dy) > 100) throw "Wheel steps must be at most 100.";
					result.push({type: type, dx: dx, dy: dy});
				case "key_down", "key_up":
					result.push({type: type, code: Keys.code(event.key), modifiers: Keys.modifiers(event.modifiers)});
				case "text":
					if (!Std.isOfType(event.text, String) || (event.text : String).length > 16000) throw "text must be a string of at most 16000 characters.";
					result.push({type: type, text: event.text});
			}
		}
		return result;
	}

	/** One event per frame, so an app that polls input each frame sees a press and a release separately. */
	static function pumpInput():Void {
		if (inputs.length == 0) return;
		var batch = inputs[0];
		if (!batch.request.waiting()) {
			inputs.shift();
			return;
		}
		if (batch.next < batch.events.length) {
			if (isSensitive()) {
				inputs.shift();
				fail(batch.request, new AgentError(423, "sensitive", "The app became sensitive; the remaining input was not sent."));
				return;
			}
			var event = batch.events[batch.next++];
			if (batch.next == batch.events.length) batch.settle = frame + 2;
			send(event);
			return;
		}
		if (frame >= batch.settle) {
			inputs.shift();
			ok(batch.request, {frame: frame});
		}
	}

	static function send(event:Dynamic):Void {
		var view = viewSize();
		var sx = window.width / view.width, sy = window.height / view.height;
		switch (event.type : String) {
			case "mouse_move": window.onMouseMove.dispatch(event.x * sx, event.y * sy);
			case "mouse_down": window.onMouseDown.dispatch(event.x * sx, event.y * sy, event.button);
			case "mouse_up": window.onMouseUp.dispatch(event.x * sx, event.y * sy, event.button);
			// Agents scroll down with a positive dy; Lime, like SDL, scrolls up with one.
			case "wheel": window.onMouseWheel.dispatch(event.dx, -event.dy, MouseWheelMode.LINES);
			case "key_down": window.onKeyDown.dispatch(event.code, event.modifiers);
			case "key_up": window.onKeyUp.dispatch(event.code, event.modifiers);
			case "text": window.onTextInput.dispatch(event.text);
		}
	}

	static function pumpWaiters():Void {
		if (waiters.length == 0) return;
		var idle = inputs.length == 0 && !isBusy();
		var now = Sys.time();
		for (waiter in waiters.copy()) {
			if (!idle) waiter.idleFrom = -1;
			else if (waiter.idleFrom < 0) waiter.idleFrom = frame;
			var settled = waiter.idleFrom >= 0 && frame - waiter.idleFrom >= waiter.quiet;
			if (!settled && now <= waiter.deadline && waiter.request.waiting()) continue;
			waiters.remove(waiter);
			var result:Dynamic = {idle: settled, frame: frame, waitedMs: Math.round((now - waiter.started) * 1000)};
			if (!settled) result.reason = inputs.length > 0 ? "input queued" : "app busy";
			ok(waiter.request, result);
		}
	}

	// Logs and errors

	static function log(level:String, message:String, ?source:String):Void {
		var entry:LogEntry = {seq: 0, time: Date.now().getTime(), level: level, message: message.length > 4000 ? message.substr(0, 4000) + "..." : message};
		if (source != null) entry.source = source;
		logs.add(entry);
	}

	/** Called from lime.utils.Log through the init macro. */
	public static function limeLog(level:String, message:Dynamic, info:Null<haxe.PosInfos>):Void {
		if (app == null) return;
		var threshold:Int = cast lime.utils.Log.level;
		if ((level == "debug" && threshold < 4) || (level == "verbose" && threshold < 5)) return;
		var source = info == null ? null : info.className;
		if (level == "error") recordError(message, CallStack.callStack().slice(2), false);
		else log(level, Std.string(message), source);
	}

	/** One entry per thrown value: OpenFL reports an error once as uncaught, then again when it ends the app. */
	public static function recordError(error:Dynamic, stack:Null<Array<StackItem>>, fatal:Bool):Void {
		if (app == null) return;
		if (lastError != null && lastErrorValue == error) {
			if (fatal) lastError.fatal = true;
			return;
		}
		lastErrorValue = error;
		lastError = errors.add({seq: 0, time: Date.now().getTime(), message: describe(error), stack: frames(stack), fatal: fatal});
		log("error", lastError.message);
	}

	/** Called from the init macro's wrapper around `Application.exec` with the error that is ending the app. */
	public static function fatal(error:Dynamic):Void {
		if (app == null || crashed) return;
		crashed = true;
		var stack:Array<StackItem> = Std.isOfType(error, haxe.Exception) ? (cast (cast error : haxe.Exception).stack : Array<StackItem>) : CallStack.exceptionStack();
		recordError(error, stack, true);
		if (id != null) try Registry.writeCrash(id, {
			pid: Native.pid(), name: appName(), time: Date.now().getTime(), message: lastError.message, stack: lastError.stack,
			logs: logs.tail(50).map(entry -> '[${entry.level}] ${entry.message}')
		}) catch (_:Dynamic) {}
		stop();
	}

	static function describe(error:Dynamic):String {
		if (Std.isOfType(error, String)) return error;
		var message = Std.isOfType(error, haxe.Exception) ? (cast error : haxe.Exception).message : Std.string(error);
		var kind = Type.getClass(error) == null ? null : Type.getClassName(Type.getClass(error));
		return kind == null ? message : '$kind: $message';
	}

	static function frames(stack:Null<Array<StackItem>>):Array<String> {
		if (stack == null) return [];
		return [for (item in stack.slice(0, 60)) StringTools.trim(StringTools.replace(CallStack.toString([item]), "Called from ", ""))];
	}

	// Helpers

	static function ok(request:Request, data:Dynamic):Void {
		if (request.waiting()) request.respond(200, Json.stringify(data));
	}

	static function fail(request:Request, error:AgentError):Void {
		if (request.waiting()) request.respond(error.status, Json.stringify({error: {code: error.code, message: error.message}}));
	}

	static function integer(value:Dynamic, fallback:Int, min:Int, max:Null<Int>):Int {
		if (value == null) return fallback;
		if (!Std.isOfType(value, Int)) throw "Expected an integer.";
		var n:Int = value;
		if (n < min || (max != null && n > max)) throw 'Expected an integer from $min${max == null ? "" : " to " + max}.';
		return n;
	}

	static function number(value:Dynamic):Float {
		if (!Std.isOfType(value, Float) && !Std.isOfType(value, Int)) throw "Expected a number.";
		var n:Float = value;
		if (!Math.isFinite(n)) throw "Expected a finite number.";
		return n;
	}

	static function constantEquals(a:String, b:String):Bool {
		if (a.length != b.length) return false;
		var difference = 0;
		for (i in 0...a.length) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
		return difference == 0;
	}

	static function appName():String {
		var name = app.meta.get("name");
		if (name == null || name == "") name = app.meta.get("file");
		return name == null || name == "" ? haxe.io.Path.withoutDirectory(haxe.io.Path.withoutExtension(Sys.programPath())) : name;
	}

	static function limeVersion():String {
		return haxe.macro.Compiler.getDefine("lime");
	}

	static function frameworks():Array<String> {
		var list = [];
		#if openfl
		list.push("openfl " + haxe.macro.Compiler.getDefine("openfl"));
		#end
		#if feathersui
		list.push("feathersui " + haxe.macro.Compiler.getDefine("feathersui"));
		#end
		#if graphaxe
		list.push("graphaxe " + haxe.macro.Compiler.getDefine("graphaxe"));
		#end
		return list;
	}
}
#end
