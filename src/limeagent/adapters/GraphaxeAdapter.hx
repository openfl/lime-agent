package limeagent.adapters;

#if graphaxe
import gx.display.DisplayObject;
import gx.display.DisplayObjectContainer;
import gx.display.Stage;
import gx.runtime.GraphaxeRuntime;
import lime.graphics.Image;
import limeagent.Adapter;

/** Graphaxe's display tree, controls and game objects alike. Captures through Graphaxe's own render target, so any backend works. */
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

	/**
		Every visible object, not only controls: a game draws its cards and pieces with sprites, quads and images, so
		each is listed with its class, name, label and text, its bounds on the stage, and whether a click reaches it.
	**/
	override public function tree(options:TreeOptions):Null<Array<TreeNode>> {
		if (!active()) return null;
		var stage = GraphaxeRuntime.current.stage;
		var nodes = [];
		children(stage, stage, nodes, options, 0, stage.visible && stage.interactive && stage.interactiveChildren);
		return nodes;
	}

	/** Lists a container's children into `out`, and returns how many the limits left out. */
	function children(container:DisplayObjectContainer, stage:Stage, out:Array<TreeNode>, options:TreeOptions, depth:Int, pointer:Bool):Int {
		var more = 0;
		for (i in 0...container.numChildren) {
			var child = container.getChildAt(i);
			if (!child.visible && !options.includeHidden) continue;
			if (options.full() || options.tooDeep(depth)) {
				more++;
				continue;
			}
			out.push(describe(child, stage, options, depth, pointer));
		}
		return more;
	}

	function describe(object:DisplayObject, stage:Stage, options:TreeOptions, depth:Int, pointer:Bool):TreeNode {
		options.count++;
		var bounds = object.getBounds(stage);
		var node:TreeNode = {kind: Adapter.shortKind(object), x: Math.round(bounds.x), y: Math.round(bounds.y),
			width: Math.round(bounds.width), height: Math.round(bounds.height)};
		var name = Adapter.meaningfulName(object.name), label = Adapter.labelOf(object), text = textOf(object);
		if (name != null) node.name = name;
		if (label != null) node.label = label;
		if (text != null) node.text = text;
		if (Std.isOfType(object, gx.ui.Control)) node.enabled = (cast object : gx.ui.Control).enabled;
		if (stage.focus == object) node.focused = true;
		// The same rules as Graphaxe's own hit test: visible and interactive all the way down from the stage.
		pointer = pointer && object.visible && object.interactive;
		if (!object.visible) node.hidden = true;
		else if (!pointer) node.pointer = false;
		else {
			var at = reach(object, stage, bounds);
			if (at == null) node.covered = true;
			else if (at.x != Math.round(bounds.x + bounds.width / 2) || at.y != Math.round(bounds.y + bounds.height / 2)) node.at = at;
		}
		// A control with its own text draws it with inner fields; listing those would repeat it.
		if (text == null && Std.isOfType(object, DisplayObjectContainer)) {
			var container:DisplayObjectContainer = cast object;
			var list = [];
			var more = children(container, stage, list, options, depth + 1, pointer && container.interactiveChildren);
			if (list.length > 0) node.children = list;
			if (more > 0) node.more = more;
		}
		return node;
	}

	/** A point on the stage where a click reaches `object`: its centre if nothing covers it, else the first of a 5 by 5 grid. */
	function reach(object:DisplayObject, stage:Stage, bounds:gx.math.Rectangle):Null<{x:Int, y:Int}> {
		var left = Math.max(0, bounds.x), top = Math.max(0, bounds.y);
		var right = Math.min(stage.stageWidth, bounds.x + bounds.width), bottom = Math.min(stage.stageHeight, bounds.y + bounds.height);
		if (right <= left || bottom <= top) return null;
		var points = [{x: Math.round(bounds.x + bounds.width / 2), y: Math.round(bounds.y + bounds.height / 2)}];
		for (row in 0...5) for (column in 0...5)
			points.push({x: Math.round(left + (right - left) * (column + 0.5) / 5), y: Math.round(top + (bottom - top) * (row + 0.5) / 5)});
		for (point in points) {
			var hit = stage.hitTest(point.x, point.y);
			while (hit != null && hit != object) hit = hit.parent;
			if (hit != null) return point;
		}
		return null;
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
