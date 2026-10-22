package limeagent.cli;

import haxe.Json;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;

/** A refusal from the app itself: an HTTP status and the protocol's error code. */
class AppError {
	public var status:Int;
	public var code:String;
	public var message:String;

	public function new(status:Int, code:String, message:String) {
		this.status = status;
		this.code = code;
		this.message = message;
	}

	public function toString():String {
		return message;
	}
}

/** The app could not be reached at all: refused, reset or timed out. */
class Unreachable {
	public var message:String;
	public var refused:Bool;

	public function new(message:String, refused:Bool) {
		this.message = message;
		this.refused = refused;
	}

	public function toString():String {
		return message;
	}
}

/** Talks to one registered app over loopback HTTP, one request per connection. */
class AppClient {
	public var entry(default, null):Dynamic;

	public function new(entry:Dynamic) {
		this.entry = entry;
	}

	public function call(op:String, ?args:Dynamic, timeoutSeconds = 10.0):Dynamic {
		return Json.parse(raw(op, args, timeoutSeconds));
	}

	/** The response body as text, for callers that read large fields without parsing them. */
	public function raw(op:String, ?args:Dynamic, timeoutSeconds = 10.0):String {
		var port:Int = entry.port;
		var body = Bytes.ofString(Json.stringify(args == null ? {} : args));
		var head = 'POST /lime-agent/v1/$op HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nAuthorization: Bearer ${entry.token}\r\n'
			+ 'Content-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n';
		var socket = new Socket();
		var response:Bytes;
		try {
			socket.setTimeout(timeoutSeconds);
			socket.connect(new Host("127.0.0.1"), port);
		} catch (error:Dynamic) {
			socket.close();
			throw new Unreachable('Could not connect to port $port: $error', true);
		}
		try {
			socket.output.writeString(head);
			socket.output.write(body);
			socket.output.flush();
			response = socket.input.readAll();
			socket.close();
		} catch (error:Dynamic) {
			socket.close();
			throw new Unreachable('The app did not answer within ${timeoutSeconds}s: $error', false);
		}
		var text = response.toString();
		var end = text.indexOf("\r\n\r\n");
		if (end < 0) throw new Unreachable("The app closed the connection without answering; it may have crashed. Call errors for its crash record.", false);
		var status = Std.parseInt(text.substring(9, 12));
		var content = text.substr(end + 4);
		if (status != 200) {
			var error:Dynamic = try Json.parse(content).error catch (_:Dynamic) null;
			throw new AppError(status, error == null ? "http_" + status : error.code, error == null ? 'HTTP $status' : error.message);
		}
		return content;
	}
}
