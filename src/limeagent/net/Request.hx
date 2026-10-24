package limeagent.net;

/** One call to an op, over HTTP or a WebSocket, answered once. An answer for a client that has gone is dropped. */
class Request {
	public var op(default, null):String;
	public var args(default, null):Dynamic;
	public var responded(default, null) = false;

	var send:(Int, String) -> Void;
	var open:Void->Bool;

	public function new(op:String, args:Dynamic, send:(Int, String) -> Void, open:Void->Bool) {
		this.op = op;
		this.args = args;
		this.send = send;
		this.open = open;
	}

	/** `json` is the result for status 200, otherwise `{"code", "message"}`. */
	public function respond(status:Int, json:String):Void {
		if (responded) return;
		responded = true;
		send(status, json);
	}

	/** True while the client is still waiting; a deferred answer can be dropped when it is gone. */
	public function waiting():Bool {
		return !responded && open();
	}
}
