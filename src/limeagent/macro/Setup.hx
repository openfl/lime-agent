package limeagent.macro;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;

/** Compiles the agent into a Lime app. Added by the haxelib's include.xml and extraParams.hxml. */
class Setup {
	public static function init():Void {
		if (Context.defined("lime_agent_active") || Context.defined("lime_agent_disable") || Context.defined("final")) return;
		if (Context.defined("display")) return;
		Compiler.define("lime_agent_active");
		// Uncaught errors are only useful with a stack; hxcpp release builds drop it without these.
		if (!Context.defined("lime_agent_no_stack")) {
			Compiler.define("HXCPP_STACK_TRACE");
			Compiler.define("HXCPP_STACK_LINE");
		}
		Compiler.addMetadata("@:build(limeagent.macro.Setup.application())", "lime.app.Application");
		Compiler.addMetadata("@:build(limeagent.macro.Setup.log())", "lime.utils.Log");
	}

	/** Attaches the agent when the first Application is constructed and records an error that ends `exec`. */
	public static function application():Array<Field> {
		var fields = Context.getBuildFields();
		for (field in fields) switch field.kind {
			case FFun(f) if (field.name == "new" && f.expr != null):
				f.expr = macro {${f.expr}; limeagent.Agent.attach(this);};
			case FFun(f) if (field.name == "exec" && f.expr != null):
				// hxcpp rethrows the original value, as OpenFL does; `throw` alone satisfies the return check.
				var rethrow = Context.defined("cpp") ? macro untyped __cpp__("throw error") : macro {};
				f.expr = macro try ${f.expr} catch (error:Dynamic) {
					limeagent.Agent.fatal(error);
					$rethrow;
					throw error;
				};
			default:
		}
		return fields;
	}

	/** Copies Lime's own warnings and errors into the agent's log before Lime prints or throws them. */
	public static function log():Array<Field> {
		var fields = Context.getBuildFields();
		for (field in fields) switch field.kind {
			case FFun(f) if (f.expr != null && ["debug", "error", "info", "verbose", "warn"].indexOf(field.name) >= 0):
				var level = field.name;
				f.expr = macro {limeagent.Agent.limeLog($v{level}, message, info); ${f.expr};};
			default:
		}
		return fields;
	}
}
#end
