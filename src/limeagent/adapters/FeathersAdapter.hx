package limeagent.adapters;

#if feathersui
import feathers.controls.TextArea;
import feathers.controls.TextInput;
import feathers.core.IFocusObject;
import feathers.core.ITextControl;
import feathers.core.IUIControl;
import limeagent.Adapter;
import openfl.display.DisplayObject;

/** Feathers UI controls by their own text and state, without the text fields inside them. */
class FeathersAdapter extends OpenFLAdapter {
	public function new() {
		super("feathersui");
	}

	override function textOf(object:DisplayObject):Null<String> {
		if (Std.isOfType(object, TextInput) && (cast object : TextInput).displayAsPassword) return "[masked]";
		if (Std.isOfType(object, ITextControl)) return Adapter.clip((cast object : ITextControl).text);
		if (Std.isOfType(object, TextArea)) return Adapter.clip((cast object : TextArea).text);
		return super.textOf(object);
	}

	override function enabledOf(object:DisplayObject):Null<Bool> {
		return Std.isOfType(object, IUIControl) && Std.isOfType(object, IFocusObject) ? (cast object : IUIControl).enabled : super.enabledOf(object);
	}

	override function interactive(object:DisplayObject):Bool {
		return Std.isOfType(object, IFocusObject) || super.interactive(object);
	}

	override function descend(object:DisplayObject):Bool {
		return !Std.isOfType(object, ITextControl) && !Std.isOfType(object, TextArea);
	}
}
#end
