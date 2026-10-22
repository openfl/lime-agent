package limeagent.http;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Host;
import sys.net.Socket;

/**
	A minimal HTTP/1.1 server on 127.0.0.1, pumped from the app's frame loop.
	One request per connection, no keep-alive, no chunked bodies, no files.
**/
class LoopbackServer {
	public static inline var MAX_CONNECTIONS = 4;
	public static inline var MAX_HEADER = 8192;
	public static inline var MAX_BODY = 65536;
	public static inline var READ_TIMEOUT = 5.0;

	public var port(default, null):Int;

	var listener:Socket;
	var clients:Array<Client> = [];

	public function new(port:Int) {
		listener = new Socket();
		try {
			listener.bind(new Host("127.0.0.1"), port);
			listener.listen(MAX_CONNECTIONS);
			listener.setBlocking(false);
		} catch (error:Dynamic) {
			listener.close();
			throw error;
		}
		this.port = listener.host().port;
	}

	/** Accepts, reads and writes without blocking. `handle` is called once per complete request. */
	public function pump(handle:Request->Void):Void {
		while (true) {
			var socket:Socket = try listener.accept() catch (_:Dynamic) null;
			if (socket == null) break;
			if (clients.length >= MAX_CONNECTIONS) {
				socket.close();
				continue;
			}
			socket.setBlocking(false);
			clients.push(new Client(socket));
		}
		for (client in clients.copy()) {
			if (client.request == null) {
				var request = client.read();
				if (request != null) handle(request);
			}
			if (!client.flush()) clients.remove(client);
		}
	}

	public function close():Void {
		for (client in clients) client.close();
		clients = [];
		listener.close();
	}
}

class Request {
	public var method(default, null):String;
	public var path(default, null):String;
	public var body(default, null):String;
	public var responded(default, null) = false;

	var headers:Map<String, String>;
	var client:Client;

	public function new(client:Client, method:String, path:String, headers:Map<String, String>, body:String) {
		this.client = client;
		this.method = method;
		this.path = path;
		this.headers = headers;
		this.body = body;
	}

	/** Header names are case-insensitive. A repeated header reads as null, so it can never satisfy a check. */
	public function header(name:String):Null<String> {
		return headers.get(name.toLowerCase());
	}

	public function hasHeader(name:String):Bool {
		return headers.exists(name.toLowerCase());
	}

	public function respond(status:Int, json:String):Void {
		if (responded) return;
		responded = true;
		var body = Bytes.ofString(json);
		var head = 'HTTP/1.1 $status ${reason(status)}\r\n' + "Content-Type: application/json; charset=utf-8\r\n" + 'Content-Length: ${body.length}\r\n'
			+ "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n";
		var out = new BytesBuffer();
		out.add(Bytes.ofString(head));
		out.add(body);
		client.send(out.getBytes());
	}

	/** True while the client is still waiting; a deferred answer can be dropped when it is gone. */
	public function waiting():Bool {
		return !responded && client.open;
	}

	static function reason(status:Int):String {
		return switch status {
			case 200: "OK";
			case 400: "Bad Request";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 405: "Method Not Allowed";
			case 411: "Length Required";
			case 413: "Payload Too Large";
			case 423: "Locked";
			case 500: "Internal Server Error";
			case 501: "Not Implemented";
			case 503: "Service Unavailable";
			case 504: "Gateway Timeout";
			default: "Status";
		}
	}
}

@:allow(limeagent.http)
class Client {
	public var open(default, null) = true;
	public var request(default, null):Request;

	var socket:Socket;
	var input = new BytesBuffer();
	var output:Bytes;
	var written = 0;
	var lingerUntil = 0.0;
	var started = Sys.time();
	var chunk = Bytes.alloc(16384);

	function new(socket:Socket) {
		this.socket = socket;
	}

	function read():Null<Request> {
		while (open) {
			var count = try socket.input.readBytes(chunk, 0, chunk.length) catch (error:haxe.io.Error) {
				if (error.match(Blocked)) 0 else {close(); return null;}
			} catch (_:Dynamic) {
				close();
				return null;
			};
			if (count <= 0) break;
			input.addBytes(chunk, 0, count);
			if (input.length > MAX_TOTAL) return fail(413, "too_large", "The request is too large.");
		}
		if (!open) return null;
		var data = input.getBytes();
		input = new BytesBuffer();
		input.add(data);
		var end = -1;
		for (i in 0...data.length - 3) if (data.get(i) == 13 && data.get(i + 1) == 10 && data.get(i + 2) == 13 && data.get(i + 3) == 10) {
			end = i;
			break;
		}
		if (end < 0) {
			if (data.length > LoopbackServer.MAX_HEADER) return fail(413, "too_large", "The request headers are too large.");
			if (Sys.time() - started > LoopbackServer.READ_TIMEOUT) close();
			return null;
		}
		var lines = data.getString(0, end).split("\r\n");
		var start = lines.shift().split(" ");
		if (start.length != 3 || !StringTools.startsWith(start[2], "HTTP/1.")) return fail(400, "bad_request", "Malformed request line.");
		var headers = new Map<String, String>(), repeated = [];
		for (line in lines) {
			var colon = line.indexOf(":");
			if (colon <= 0) return fail(400, "bad_request", "Malformed header.");
			var name = StringTools.trim(line.substr(0, colon)).toLowerCase();
			if (headers.exists(name)) repeated.push(name);
			headers.set(name, StringTools.trim(line.substr(colon + 1)));
		}
		for (name in repeated) headers.set(name, null);
		if (headers.exists("transfer-encoding")) return fail(411, "bad_request", "Chunked bodies are not accepted.");
		var lengthText = headers.get("content-length");
		var length = lengthText == null ? 0 : Std.parseInt(lengthText);
		if (length == null || length < 0 || !~/^[0-9]*$/.match(lengthText == null ? "" : lengthText)) return fail(400, "bad_request", "Invalid Content-Length.");
		if (length > LoopbackServer.MAX_BODY) return fail(413, "too_large", "The request body is too large.");
		var bodyStart = end + 4;
		if (data.length - bodyStart < length) {
			if (Sys.time() - started > LoopbackServer.READ_TIMEOUT) close();
			return null;
		}
		var body = data.getString(bodyStart, length);
		request = new Request(this, start[0], start[1], headers, body);
		return request;
	}

	static inline var MAX_TOTAL = LoopbackServer.MAX_HEADER + LoopbackServer.MAX_BODY + 4;

	function fail(status:Int, code:String, message:String):Null<Request> {
		request = new Request(this, "", "", new Map(), "");
		request.respond(status, haxe.Json.stringify({error: {code: code, message: message}}));
		return null;
	}

	function send(bytes:Bytes):Void {
		output = bytes;
		written = 0;
	}

	/** Writes what it can. False once the connection is finished and can be forgotten. */
	function flush():Bool {
		if (!open) return false;
		if (output == null) return true;
		while (written < output.length) {
			var count = try socket.output.writeBytes(output, written, output.length - written) catch (error:haxe.io.Error) {
				if (error.match(Blocked)) 0 else {close(); return false;}
			} catch (_:Dynamic) {
				close();
				return false;
			};
			if (count <= 0) return true;
			written += count;
		}
		return linger();
	}

	/**
		Closing with unread request bytes makes the system reset the connection, which can discard the answer
		before the client reads it. So stop sending, read and drop what the client still sends, then close.
	**/
	function linger():Bool {
		if (lingerUntil == 0) {
			lingerUntil = Sys.time() + 2;
			try socket.shutdown(false, true) catch (_:Dynamic) {}
		}
		while (true) {
			var count = try socket.input.readBytes(chunk, 0, chunk.length) catch (error:haxe.io.Error) {
				if (error.match(Blocked)) 0 else -1;
			} catch (_:Dynamic) -1;
			if (count < 0) break;
			if (count == 0) {
				if (Sys.time() < lingerUntil) return true;
				break;
			}
		}
		close();
		return false;
	}

	function close():Void {
		if (!open) return;
		open = false;
		try socket.close() catch (_:Dynamic) {}
	}
}
