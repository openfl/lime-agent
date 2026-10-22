package limeagent.adapters;

#if graphaxe
import gx.display.DisplayObject;
import gx.display.DisplayObjectContainer;
import gx.runtime.GraphaxeRuntime;
import lime.graphics.Image;
import limeagent.Adapter;

/** Graphaxe's stage and gx.ui controls. Captures through Graphaxe's own render target, so any backend works. */
class GraphaxeAdapter extends Adapter {
	public function new() {
		super("graphaxe");
	}

	override public function active():Bool {
		return GraphaxeRuntime.current != null && GraphaxeRuntime.current.stage != null;
	}

	override public function viewSize():Null<{width:Int, height:Int}> {
		if (!active()) return null;
		var stage = GraphaxeRuntime.current.stage;
		return {width: stage.stageWidth, height: stage.stageHeight};
	}

	override public function capture():Null<Image> {
		if (!active()) return null;
		var pixels = GraphaxeRuntime.current.capture(1);
		if (pixels == null) return null;
		try {
			var image = pixels.image.clone();
			pixels.dispose();
			return image;
		} catch (error:Dynamic) {
			pixels.dispose();
			throw error;
		}
	}

	override public function tree(options:TreeOptions):Null<Array<TreeNode>> {
		if (!active()) return null;
		var nodes = [];
		visit(GraphaxeRuntime.current.stage, nodes, options);
		return nodes;
	}

	function visit(object:DisplayObject, out:Array<TreeNode>, options:TreeOptions):Void {
		if (options.full() || (!object.visible && !options.includeHidden)) return;
		var text = textOf(object);
		var name = Adapter.meaningfulName(object.name);
		var control = Std.isOfType(object, gx.ui.Control);
		var children = [];
		// A control with its own text draws it with inner fields; listing those would repeat it.
		if (text == null && Std.isOfType(object, DisplayObjectContainer)) {
			var container:DisplayObjectContainer = cast object;
			for (i in 0...container.numChildren) visit(container.getChildAt(i), children, options);
		}
		if (text == null && name == null && !control) {
			for (child in children) out.push(child);
			return;
		}
		var point = object.localToGlobal(0, 0);
		var node:TreeNode = {kind: Adapter.shortKind(object), x: Math.round(point.x), y: Math.round(point.y),
			width: Math.round(object.width), height: Math.round(object.height)};
		if (name != null) node.name = name;
		if (text != null) node.text = text;
		if (control) node.enabled = (cast object : gx.ui.Control).enabled;
		if (GraphaxeRuntime.current.stage.focus == object) node.focused = true;
		if (children.length > 0) node.children = children;
		options.count++;
		out.push(node);
	}

	function textOf(object:DisplayObject):Null<String> {
		if (Std.isOfType(object, gx.ui.TextInput)) {
			var input:gx.ui.TextInput = cast object;
			return input.displayAsPassword ? "[masked]" : Adapter.clip(input.text);
		}
		if (Std.isOfType(object, gx.text.TextField)) {
			var field:gx.text.TextField = cast object;
			return field.displayAsPassword ? "[masked]" : Adapter.clip(field.text);
		}
		if (Std.isOfType(object, gx.ui.Button)) return Adapter.clip((cast object : gx.ui.Button).text);
		if (Std.isOfType(object, gx.ui.Label)) return Adapter.clip((cast object : gx.ui.Label).text);
		if (Std.isOfType(object, gx.ui.BaseTextEditorControl)) return Adapter.clip((cast object : gx.ui.BaseTextEditorControl).text);
		return null;
	}
}
#end
