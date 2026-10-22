package limeagent;

/** A bounded ring of entries numbered from 1, so readers can ask for everything after the last one they saw. */
class Journal<T:{seq:Int}> {
	public var capacity(default, null):Int;
	public var last(default, null) = 0;

	var entries:Array<T> = [];

	public function new(capacity:Int) {
		this.capacity = capacity;
	}

	public function add(entry:T):T {
		entry.seq = ++last;
		entries.push(entry);
		if (entries.length > capacity) entries.shift();
		return entry;
	}

	public function newest():Null<T> {
		return entries.length == 0 ? null : entries[entries.length - 1];
	}

	/**
		With `since` 0, the newest `limit` entries. Otherwise entries after `since`, oldest first, at most `limit`,
		so a reader pages forward by passing back `next`. `dropped` counts entries after `since` that the ring lost.
	**/
	public function since(since:Int, limit:Int, ?accept:T->Bool):{entries:Array<T>, next:Int, dropped:Int} {
		var first = entries.length == 0 ? last + 1 : entries[0].seq;
		var result = [for (entry in entries) if (entry.seq > since && (accept == null || accept(entry))) entry];
		var more = since > 0 && result.length > limit;
		if (result.length > limit) result = since <= 0 ? result.slice(result.length - limit) : result.slice(0, limit);
		var next = more ? result[result.length - 1].seq : last;
		return {entries: result, next: next, dropped: since > 0 && since + 1 < first ? first - since - 1 : 0};
	}

	public function tail(count:Int):Array<T> {
		return entries.slice(Std.int(Math.max(0, entries.length - count)));
	}
}
