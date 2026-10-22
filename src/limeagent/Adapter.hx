package limeagent;

import lime.graphics.Image;

typedef TreeNode = {
	kind:String,
	?name:String,
	?text:String,
	x:Int,
	y:Int,
	width:Int,
	height:Int,
	?enabled:Bool,
	?focused:Bool,
	?children:Array<TreeNode>
}

/** Limits for one `tree` request; adapters stop adding nodes once `full()`. */
class TreeOptions {
	public var maxNodes(default, null):Int;
	public var includeHidden(default, null):Bool;
	public var count = 0;
	public var truncated = false;

	public function new(maxNodes:Int, includeHidden:Bool) {
		this.maxNodes = maxNodes;
		this.includeHidden = includeHidden;
	}

	public function full():Bool {
		if (count >= maxNodes) truncated = true;
		return truncated;
	}
}

/**
	What a UI framework adds on top of Lime. Every method is optional; null means "not mine, ask the next adapter".
	All coordinates an adapter reports are in its `viewSize()` space, which is also the size of its `capture()`.
**/
class Adapter {
	public var name(default, null):String;

	public function new(name:String) {
		this.name = name;
	}

	/** False while the framework has nothing on screen yet. */
	public function active():Bool {
		return true;
	}

	/** Called once when the agent starts, for hooks such as uncaught error events. */
	public function install():Void {}

	public function viewSize():Null<{width:Int, height:Int}> {
		return null;
	}

	/** An image of exactly `viewSize()`, taken immediately; null to use the window framebuffer at the end of the next render. */
	public function capture():Null<Image> {
		return null;
	}

	/** Frameworks that skip unchanged frames render one more so the framebuffer can be read. */
	public function requestRender():Void {}

	public function tree(options:TreeOptions):Null<Array<TreeNode>> {
		return null;
	}

	static var defaultName = ~/^instance[0-9]+$/;

	public static function meaningfulName(name:Null<String>):Null<String> {
		return name == null || name == "" || defaultName.match(name) ? null : name;
	}

	public static function clip(text:Null<String>):Null<String> {
		return text == null || text == "" ? null : text.length > 2000 ? text.substr(0, 2000) + "..." : text;
	}

	public static function shortKind(value:Dynamic):String {
		var name = Type.getClassName(Type.getClass(value));
		return name == null ? "Object" : name.substr(name.lastIndexOf(".") + 1);
	}
}
