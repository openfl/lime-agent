package limeagent.adapters;

#if openfl
import limeagent.Adapter;
import openfl.Lib;
import openfl.display.DisplayObject;
import openfl.display.DisplayObjectContainer;
import openfl.display.SimpleButton;
import openfl.display.Sprite;
import openfl.display.Stage;
import openfl.events.UncaughtErrorEvent;
import openfl.text.TextField;

/** The OpenFL display list. Uninteresting containers are flattened away so the tree stays short. */
class OpenFLAdapter extends Adapter {
	public function new(name = "openfl") {
		super(name);
	}

	function stage():Null<Stage> {
		return Lib.current == null ? null : Lib.current.stage;
	}

	override public function active():Bool {
		return stage() != null;
	}

	override public function install():Void {
		Lib.current.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR,
			(event:UncaughtErrorEvent) -> Agent.recordError(event.error, haxe.CallStack.exceptionStack(), false));
	}

	override public function viewSize():Null<{width:Int, height:Int}> {
		var stage = stage();
		return stage == null ? null : {width: stage.stageWidth, height: stage.stageHeight};
	}

	@:access(openfl.display.Stage)
	override public function requestRender():Void {
		var stage = stage();
		if (stage != null) stage.__renderDirty = true;
	}

	override public function tree(options:TreeOptions):Null<Array<TreeNode>> {
		var stage = stage();
		if (stage == null) return null;
		var nodes = [];
		visit(stage, stage, nodes, options);
		return nodes;
	}

	function visit(object:DisplayObject, stage:Stage, out:Array<TreeNode>, options:TreeOptions):Void {
		if (options.full() || (!object.visible && !options.includeHidden)) return;
		var node = describe(object, stage);
		var children = [];
		if (descend(object) && Std.isOfType(object, DisplayObjectContainer)) {
			var container:DisplayObjectContainer = cast object;
			for (i in 0...container.numChildren) visit(container.getChildAt(i), stage, children, options);
		}
		if (node == null) {
			for (child in children) out.push(child);
			return;
		}
		if (children.length > 0) node.children = children;
		options.count++;
		out.push(node);
	}

	/** Null for objects with no text, no name and no sign of being clickable; their children are kept. */
	function describe(object:DisplayObject, stage:Stage):Null<TreeNode> {
		var text = textOf(object);
		var name = Adapter.meaningfulName(object.name);
		var enabled = enabledOf(object);
		if (text == null && name == null && enabled == null && !interactive(object)) return null;
		var bounds = object.getBounds(stage);
		var node:TreeNode = {kind: Adapter.shortKind(object), x: Math.round(bounds.x), y: Math.round(bounds.y),
			width: Math.round(bounds.width), height: Math.round(bounds.height)};
		if (name != null) node.name = name;
		if (text != null) node.text = text;
		if (enabled != null) node.enabled = enabled;
		if (stage.focus == object) node.focused = true;
		return node;
	}

	function textOf(object:DisplayObject):Null<String> {
		if (!Std.isOfType(object, TextField)) return null;
		var field:TextField = cast object;
		return field.displayAsPassword ? "[masked]" : Adapter.clip(field.text);
	}

	function enabledOf(object:DisplayObject):Null<Bool> {
		return Std.isOfType(object, SimpleButton) ? (cast object : SimpleButton).enabled : null;
	}

	function interactive(object:DisplayObject):Bool {
		return Std.isOfType(object, SimpleButton) || (Std.isOfType(object, Sprite) && (cast object : Sprite).buttonMode);
	}

	function descend(object:DisplayObject):Bool {
		return true;
	}
}
#end
