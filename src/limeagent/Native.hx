package limeagent;

/** The two operating system facts neither the Haxe standard library nor crossbyte gives: the pid and file modes. */
#if cpp
@:cppFileCode('
#ifdef HX_WINDOWS
#include <Windows.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

static int lime_agent_pid() {
#ifdef HX_WINDOWS
	return (int)::GetCurrentProcessId();
#else
	return (int)::getpid();
#endif
}

static bool lime_agent_chmod(const char *path, int mode) {
#ifdef HX_WINDOWS
	return true;
#else
	return ::chmod(path, (mode_t)mode) == 0;
#endif
}
')
#end
class Native {
	public static function pid():Int {
		#if cpp
		return untyped __cpp__("lime_agent_pid()");
		#else
		return 0;
		#end
	}

	/** True when the mode was applied; always true on Windows, where the profile ACL protects the registry. */
	public static function chmod(path:String, mode:Int):Bool {
		#if cpp
		return untyped __cpp__("lime_agent_chmod({0}.utf8_str(), {1})", path, mode);
		#else
		return Sys.systemName() == "Windows";
		#end
	}
}
