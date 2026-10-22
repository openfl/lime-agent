package limeagent;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/** Key names agents use, mapped to Lime's key codes and modifier bits. */
class Keys {
	public static function code(name:String):KeyCode {
		if (name == null || name == "") throw "A key name is required.";
		// Lime's printable key codes are the unshifted characters themselves.
		if (name.length == 1) {
			var c = name.toLowerCase().charCodeAt(0);
			if (c >= 0x20 && c < 0x7F) return cast c;
		}
		var lower = name.toLowerCase();
		var f = ~/^f([1-9]|1[0-2])$/;
		if (f.match(lower)) return cast(KeyCode.F1 + Std.parseInt(f.matched(1)) - 1);
		return switch lower {
			case "enter", "return": KeyCode.RETURN;
			case "tab": KeyCode.TAB;
			case "escape", "esc": KeyCode.ESCAPE;
			case "backspace": KeyCode.BACKSPACE;
			case "delete", "del": KeyCode.DELETE;
			case "insert": KeyCode.INSERT;
			case "space": KeyCode.SPACE;
			case "left": KeyCode.LEFT;
			case "right": KeyCode.RIGHT;
			case "up": KeyCode.UP;
			case "down": KeyCode.DOWN;
			case "home": KeyCode.HOME;
			case "end": KeyCode.END;
			case "pageup": KeyCode.PAGE_UP;
			case "pagedown": KeyCode.PAGE_DOWN;
			case "shift": KeyCode.LEFT_SHIFT;
			case "ctrl", "control": KeyCode.LEFT_CTRL;
			case "alt": KeyCode.LEFT_ALT;
			case "meta", "cmd", "command", "super": KeyCode.LEFT_META;
			default: throw 'Unknown key "$name".';
		}
	}

	public static function modifiers(names:Null<Array<String>>):KeyModifier {
		var bits = 0;
		if (names != null) for (name in names) bits |= switch Std.string(name).toLowerCase() {
			case "shift": KeyModifier.LEFT_SHIFT;
			case "ctrl", "control": KeyModifier.LEFT_CTRL;
			case "alt": KeyModifier.LEFT_ALT;
			case "meta", "cmd", "command", "super": KeyModifier.LEFT_META;
			default: throw 'Unknown modifier "$name".';
		}
		return cast bits;
	}
}
