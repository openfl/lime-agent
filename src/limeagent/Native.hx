package limeagent;

import haxe.io.Bytes;

/** The few operating system facts the Haxe standard library does not give: pid, secure random bytes, file modes. */
#if cpp
@:cppFileCode('
#ifdef HX_WINDOWS
#include <Windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#else
#include <errno.h>
#include <fcntl.h>
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

static bool lime_agent_random(unsigned char *out, int length) {
#ifdef HX_WINDOWS
	return ::BCryptGenRandom(NULL, (PUCHAR)out, (ULONG)length, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#else
	int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
	if (fd < 0) return false;
	int filled = 0;
	while (filled < length) {
		ssize_t n = ::read(fd, out + filled, (size_t)(length - filled));
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) break;
		filled += (int)n;
	}
	::close(fd);
	return filled == length;
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

	public static function secureRandom(length:Int):Bytes {
		var bytes = Bytes.alloc(length);
		#if cpp
		var data = bytes.getData();
		var ok:Bool = untyped __cpp__("lime_agent_random((unsigned char *)&{0}[0], {1})", data, length);
		if (!ok) throw "No secure random source is available.";
		#else
		if (!sys.FileSystem.exists("/dev/urandom")) throw "No secure random source is available; set LIME_AGENT_TOKEN.";
		var input = sys.io.File.read("/dev/urandom", true);
		try {input.readFullBytes(bytes, 0, length); input.close();} catch (error:Dynamic) {input.close(); throw error;}
		#end
		return bytes;
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
