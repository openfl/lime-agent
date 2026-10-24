package limeagent.net;

#if lime_agent_active
import crossbyte.core.HostApplication;
import crossbyte.crypto.ConstantTime;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import haxe.Json;
import haxe.io.Bytes;

/**
	The app's endpoint: HTTP and a WebSocket on 127.0.0.1, both from crossbyte, advanced from the app's frame loop.
	Every request is checked here (a loopback Host, no browser Origin, the bearer token) before the agent sees it.
**/
class Endpoint {
	public static inline var MAX_CONNECTIONS = 4;
	public static inline var MAX_BODY = 65536;
	public static inline var READ_TIMEOUT = 5.0;
	// A screenshot of a large window is several megabytes of base64, sent whole.
	static inline var MAX_OUTPUT = 64 * 1024 * 1024;

	public var port(default, null):Int;
	public var webSocketPort(default, null):Int;

	var prefix:String;
	var token:Bytes;
	var handle:Request->Void;
	var runtime:Null<Runtime>;
	var http:HTTPServer;
	var webSocket:ServerWebSocket;
	var sessions:Array<Session> = [];
	var last = Sys.time();

	/** Port 0 binds a free one. `handle` is called once per checked request, over either transport. */
	public function new(port:Int, webSocketPort:Int, token:String, prefix:String, handle:Request->Void) {
		this.token = Bytes.ofString("Bearer " + token);
		this.prefix = prefix;
		this.handle = handle;
		// An app that runs crossbyte itself already advances it; otherwise the agent makes the runtime and advances it.
		if (crossbyte.core.Application.application == null) {
			runtime = new Runtime();
			Logger.setLevel("http.access", LogLevel.OFF);
		}
		// HTTPServer announces itself at INFO; the agent prints its own line.
		var level = Logger.level;
		Logger.level = LogLevel.WARN;
		try {
			http = new HTTPServer(config(port));
			this.port = http.localPort;
			webSocket = new ServerWebSocket();
			webSocket.maxConnections = MAX_CONNECTIONS;
			webSocket.maxPendingHandshakes = MAX_CONNECTIONS;
			webSocket.handshakeTimeout = READ_TIMEOUT;
			webSocket.maxMessageSize = MAX_BODY;
			webSocket.maxOutputBufferSize = MAX_OUTPUT;
			webSocket.upgrade = upgrade;
			webSocket.addEventListener(ServerSocketConnectEvent.CONNECT, event -> open(cast event.socket));
			webSocket.bind(webSocketPort, "127.0.0.1");
			webSocket.listen(MAX_CONNECTIONS);
			this.webSocketPort = webSocket.localPort;
		} catch (error:Dynamic) {
			Logger.level = level;
			close();
			throw error;
		}
		Logger.level = level;
	}

	/** Once per frame: accepts, reads and writes without blocking. */
	public function pump():Void {
		var now = Sys.time();
		if (runtime != null) runtime.advance(Math.min(0.25, now - last), 0);
		last = now;
	}

	/** Sends `entry` as an `event` to every WebSocket session that subscribed to that kind. */
	public function publish(event:String, entry:Dynamic):Void {
		var message:String = null;
		for (session in sessions) if (session.events.indexOf(event) >= 0) {
			if (message == null) message = Json.stringify({event: event, entry: entry});
			session.send(message);
		}
	}

	/** Sends what is waiting (a fatal error to subscribers, say) and the close frames, then stops listening. */
	public function close():Void {
		handle = request -> request.respond(503, error("unavailable", "The app is exiting."));
		if (runtime != null) try pump() catch (_:Dynamic) {}
		for (session in sessions.copy()) session.close();
		sessions = [];
		if (runtime != null) try pump() catch (_:Dynamic) {}
		if (webSocket != null) try webSocket.close() catch (_:Dynamic) {}
		if (http != null) try http.drain(0) catch (_:Dynamic) {}
		webSocket = null;
		http = null;
	}

	function config(port:Int):HTTPServerConfig {
		var config = new HTTPServerConfig("127.0.0.1", port);
		config.maxConnections = MAX_CONNECTIONS;
		config.maxRequestBodySize = MAX_BODY;
		config.requestTimeout = READ_TIMEOUT;
		config.maxOutputBufferSize = MAX_OUTPUT;
		config.keepAlive = false;
		config.compression.enabled = false;
		// Loopback behind a token: nothing to rate limit, and a busy agent should not be told to wait.
		config.rateLimitKey = _ -> null;
		config.middleware.push((request, _) -> receive(request));
		return config;
	}

	// HTTP: one request per connection, POST /lime-agent/v1/<op> with a JSON object.

	function receive(request:HTTPRequestHandler):Void {
		var answer = (status:Int, json:String) -> request.respond(status, "application/json; charset=utf-8", json, HEADERS);
		var type = request.getHeader("Content-Type");
		// A non-JSON type is how a page posts a form across origins; refused with the other browser checks.
		if (!authorized(request.getHeader("Host"), port, request.hasHeader("Origin"), request.getHeader("Authorization"))
			|| type == null || !StringTools.startsWith(type.toLowerCase(), "application/json"))
			return answer(403, error("unauthorized", "Authorization required."));
		if (request.method != "POST") return answer(405, error("bad_request", "Use POST."));
		var path = request.requestPath;
		if (!StringTools.startsWith(path, prefix)) return answer(404, error("unknown_op", 'Unknown endpoint; this app speaks its protocol at $prefix.'));
		var args:Dynamic = try parse(request.requestText) catch (message:String) return answer(400, error("bad_request", message));
		handle(new Request(path.substr(prefix.length), args, (status, json) -> answer(status, status == 200 ? json : wrap(json)), () -> request.connected));
	}

	static var HEADERS = [new URLRequestHeader("Cache-Control", "no-store"), new URLRequestHeader("X-Content-Type-Options", "nosniff")];

	// WebSocket: ws://127.0.0.1:<port>/lime-agent/v1, the same checks at the upgrade, then JSON messages both ways.

	function upgrade(request:crossbyte.net.WebSocketRequest):Bool {
		if (!authorized(request.header("host"), webSocketPort, request.header("origin") != null, request.header("authorization"))) return false;
		var base = prefix.substr(0, prefix.length - 1);
		if (request.path != base && request.path != prefix) {
			request.status = 404;
			return false;
		}
		return true;
	}

	function open(socket:WebSocket):Void {
		var session = new Session(socket);
		sessions.push(session);
		socket.addEventListener(Event.CLOSE, _ -> sessions.remove(session));
		socket.addEventListener(WebSocketMessageEvent.MESSAGE, message -> {
			if (!message.isText) session.send(Json.stringify({id: null, status: 400, error: {code: "bad_request", message: "Send JSON as text messages."}}));
			else session.receive(message.text, handle);
		});
	}

	/** Loopback host on this port, no browser origin, and the bearer token. */
	function authorized(host:Null<String>, port:Int, origin:Bool, authorization:Null<String>):Bool {
		if (origin) return false;
		if (host != '127.0.0.1:$port' && host != 'localhost:$port') return false;
		return authorization != null && ConstantTime.equals(Bytes.ofString(authorization), token);
	}

	public static function parse(body:String):Dynamic {
		var args:Dynamic = body == "" ? {} : try Json.parse(body) catch (_:Dynamic) throw "The body must be JSON.";
		if (args == null || Type.typeof(args) != TObject) throw "The body must be a JSON object.";
		return args;
	}

	public static function error(code:String, message:String):String {
		return Json.stringify({code: code, message: message});
	}

	/** An HTTP failure is `{"error": {...}}`. */
	static function wrap(error:String):String {
		return '{"error":$error}';
	}
}

/** crossbyte's runtime when the app has none of its own: advanced from Lime's frame loop, never a loop of its own. */
private class Runtime extends HostApplication {
	public function new() {
		super();
	}
}

/**
	One WebSocket client. It sends `{"id", "op", "args"}`; each answer is `{"id", "status", "result"}` or
	`{"id", "status", "error"}`, with the status the same call would get over HTTP. Answers can come out of order.
	`subscribe` with `events: ["log", "error"]` adds pushed `{"event", "entry"}` messages.
**/
private class Session {
	public static var EVENTS = ["log", "error"];

	public var events(default, null):Array<String> = [];

	var socket:WebSocket;

	public function new(socket:WebSocket) {
		this.socket = socket;
	}

	public function receive(text:String, handle:Request->Void):Void {
		var message:Dynamic = null, id:Dynamic = null;
		try {
			message = Endpoint.parse(text);
			id = message.id;
			if (!Std.isOfType(message.op, String)) throw "op must be a string.";
		} catch (error:String) {
			return answer(id, 400, Endpoint.error("bad_request", error));
		}
		var args:Dynamic = message.args == null ? {} : message.args;
		if (Type.typeof(args) != TObject) return answer(id, 400, Endpoint.error("bad_request", "args must be a JSON object."));
		if (message.op == "subscribe") return subscribe(id, args);
		handle(new Request(message.op, args, (status, json) -> answer(id, status, json), open));
	}

	function subscribe(id:Dynamic, args:Dynamic):Void {
		var list:Array<Dynamic> = Std.isOfType(args.events, Array) ? args.events : null;
		if (list == null || list.filter(e -> EVENTS.indexOf(e) < 0).length > 0)
			return answer(id, 400, Endpoint.error("bad_request", 'events must be a list of ${EVENTS.join(", ")}.'));
		events = [for (e in EVENTS) if (list.indexOf(e) >= 0) e];
		answer(id, 200, Json.stringify({events: events}));
	}

	function answer(id:Dynamic, status:Int, json:String):Void {
		send('{"id":${Json.stringify(id)},"status":$status,${status == 200 ? '"result"' : '"error"'}:$json}');
	}

	public function send(text:String):Void {
		if (open()) try socket.sendText(text) catch (_:Dynamic) {}
	}

	public function open():Bool {
		return socket.connected;
	}

	public function close():Void {
		try socket.closeWith(1001, "The app is exiting.") catch (_:Dynamic) {}
	}
}
#end
