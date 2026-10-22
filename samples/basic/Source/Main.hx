package;

import lime.app.Application;
import lime.graphics.RenderContext;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
#if lime_agent
import limeagent.Adapter;
import limeagent.LimeAgent;
#end

/**
	A plain Lime app, no framework, that exercises every lime-agent endpoint:
	a button that counts clicks, a bar that grows with typed text, keys for busy, sensitive, errors and a crash.
**/
class Main extends Application {
	public static inline var BUTTON_X = 40;
	public static inline var BUTTON_Y = 40;
	public static inline var BUTTON_W = 200;
	public static inline var BUTTON_H = 80;
	public static inline var BAR_Y = 160;

	public var clicks = 0;
	public var typed = "";
	public var lastKey = "";
	public var wheel = 0.0;

	var busyUntil = 0.0;
	var sensitiveUntil = 0.0;

	public function new() {
		super();
		#if lime_agent
		LimeAgent.busy = () -> Sys.time() < busyUntil;
		LimeAgent.sensitive = () -> Sys.time() < sensitiveUntil;
		LimeAgent.addInfo("clicks", () -> clicks);
		LimeAgent.addInfo("typed", () -> typed);
		LimeAgent.addInfo("lastKey", () -> lastKey);
		LimeAgent.addInfo("wheel", () -> wheel);
		LimeAgent.addCommand("reset", _ -> {
			clicks = 0;
			typed = "";
			return {clicks: clicks};
		});
		LimeAgent.addAdapter(new SampleAdapter(this));
		#end
	}

	override public function onMouseDown(x:Float, y:Float, button:MouseButton):Void {
		if (button == LEFT && x >= BUTTON_X && x < BUTTON_X + BUTTON_W && y >= BUTTON_Y && y < BUTTON_Y + BUTTON_H) {
			clicks++;
			trace("clicked " + clicks);
		}
	}

	override public function onMouseWheel(deltaX:Float, deltaY:Float, deltaMode:MouseWheelMode):Void {
		wheel += deltaY;
	}

	override public function onTextInput(text:String):Void {
		typed += text;
	}

	override public function onKeyDown(key:KeyCode, modifier:KeyModifier):Void {
		lastKey = (modifier.ctrlKey ? "ctrl+" : "") + (modifier.shiftKey ? "shift+" : "") + Std.string(key);
		switch key {
			case BACKSPACE: typed = typed.substr(0, typed.length - 1);
			case F2: busyUntil = Sys.time() + 0.5;
			case F3: sensitiveUntil = Sys.time() + 1.5;
			case F4:
				#if lime_agent
				LimeAgent.reportError("sample reported error");
				#end
			case F5: lime.utils.Log.warn("sample warning");
			case F12: throw "sample crash";
			default:
		}
	}

	override public function render(context:RenderContext):Void {
		switch context.type {
			case OPENGL, OPENGLES, WEBGL:
				var gl = context.webgl;
				var scale = window.scale, height = Math.round(window.height * scale);
				gl.clearColor(0.15, 0.15, 0.18, 1);
				gl.clear(gl.COLOR_BUFFER_BIT);
				gl.enable(gl.SCISSOR_TEST);
				function rect(x:Float, y:Float, w:Float, h:Float, r:Float, g:Float, b:Float) {
					if (w <= 0) return;
					gl.scissor(Math.round(x * scale), height - Math.round((y + h) * scale), Math.round(w * scale), Math.round(h * scale));
					gl.clearColor(r, g, b, 1);
					gl.clear(gl.COLOR_BUFFER_BIT);
				}
				// Blue for an even number of clicks, orange for odd.
				if (clicks % 2 == 0) rect(BUTTON_X, BUTTON_Y, BUTTON_W, BUTTON_H, 0, 0.4, 1) else rect(BUTTON_X, BUTTON_Y, BUTTON_W, BUTTON_H, 1, 0.5, 0);
				rect(BUTTON_X, BAR_Y, Math.min(typed.length * 10, 500), 20, 0, 0.8, 0.2);
				gl.disable(gl.SCISSOR_TEST);
			default:
		}
	}
}

#if lime_agent
/** A plain Lime app has no display list, so it describes its own controls. */
class SampleAdapter extends Adapter {
	var main:Main;

	public function new(main:Main) {
		super("sample");
		this.main = main;
	}

	override public function tree(options:TreeOptions):Null<Array<TreeNode>> {
		var s = main.window.scale;
		function px(v:Float) return Math.round(v * s);
		options.count += 2;
		return [
			{kind: "Button", name: "counter", text: 'Clicked ${main.clicks}', x: px(Main.BUTTON_X), y: px(Main.BUTTON_Y), width: px(Main.BUTTON_W),
				height: px(Main.BUTTON_H), enabled: true},
			{kind: "TextInput", name: "typed", text: main.typed, x: px(Main.BUTTON_X), y: px(Main.BAR_Y), width: px(500), height: px(20), focused: true}
		];
	}
}
#end
