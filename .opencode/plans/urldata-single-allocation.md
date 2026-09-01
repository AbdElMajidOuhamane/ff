# UrlData single-allocation layout — skill-compliant solution (v1+v2)

## Goal
`new URL(...)` performs **1 persistent allocation** (the refcounted block) and
**0 transient allocations** — down from 12–16 — while preserving semantics
(decoded components, `searchParams` shared with the URL object) and deleting
the `owned`-flag ownership bug class entirely. All changes are in
**`src/api/url.zig`** only.

## Why this satisfies the skill
- One dense contiguous block (cache-local; `serialize`/`href` reads become one scan, no pointer chasing)
- `PoolSlice {off: u32, len: u32}` fields — struct stride shrinks, matches the existing `HeadersData`/`RequestData` pool idiom
- Zero dynamic allocations in the construction path (the skill's hot-path rule)
- Ownership = explicit refcount handle (same proven pattern as `HeadersData`), replacing the `owned` flag that caused two segfaults
- `comptime` size asserts + before/after benchmark (`bench/api_micro.js`, baseline: `new URL` 2.15 µs/op)

## Layout

```
┌───────────────────────────────────────────────┐ ← one gpa.alignedAlloc
│ UrlBlock: mem_len: u32, refs: u32,            │
│   sp: URLSearchParamsData (embedded),         │
│   url: UrlData (slices → pool)                │
│ pool bytes: scheme·host·path·query·fragment·  │
│   user·pass·href·origin·host_str·search·hash  │
└───────────────────────────────────────────────┘
refs = 2 at construction (urlFinalizer + spFinalizer); release() frees at 0.
```

## 1) New types (replace `UrlData`, `URLSearchParamsData.owned`, add `UrlBlock`)

```zig
const PoolSlice = @import("../types/pool_slice.zig").PoolSlice; // {off: u32, len: u32}

const UrlData = struct {
    block: *UrlBlock, // ownership handle (NOT freed here)
    pool: [*]u8,
    port: ?u16 = null,
    scheme: []const u8 = "",   // all slices point into the block pool —
    host: []const u8 = "",     // existing call sites (data.host, data.path, …)
    path: []const u8 = "",     // keep working unchanged
    query: []const u8 = "",
    fragment: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    href: []const u8 = "",     // precomputed at parse (replaces serialize())
    origin: []const u8 = "",   // replaces originStr()
    host_str: []const u8 = "", // replaces hostStr()
    search: []const u8 = "",   // replaces searchStr()
    hash: []const u8 = "",     // replaces hashStr()
    port_str: []const u8 = "", // replaces portStr()
    // deinit DELETED — UrlBlock.release owns everything
};

const UrlBlock = struct {
    mem_len: u32,
    refs: u32,
    sp: URLSearchParamsData, // embedded; its ArrayLists stay heap-backed (mutation growth)
    url: UrlData,

    fn create(pool_len: usize) !*UrlBlock {
        const hdr = std.mem.alignForward(usize, @sizeOf(UrlBlock), 8);
        const total = hdr + pool_len;
        const mem = try gpa.alignedAlloc(u8, .of(UrlBlock), total);
        const block: *UrlBlock = @ptrCast(@alignCast(mem.ptr));
        block.* = .{
            .mem_len = @intCast(total),
            .refs = 1, // the URL object's ref
            .sp = URLSearchParamsData.init(),
            .url = .{ .block = block, .pool = mem.ptr + hdr },
        };
        return block;
    }
    fn poolSlice(self: *UrlBlock) []u8 {
        const hdr = std.mem.alignForward(usize, @sizeOf(UrlBlock), 8);
        return (@as([*]u8, @ptrCast(self)) + hdr)[0 .. self.mem_len - hdr];
    }
    fn retain(self: *UrlBlock) void {
        self.refs += 1;
    }
    fn release(self: *UrlBlock) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.sp.deinit();
            gpa.free(@as([*]u8, @ptrCast(self))[0..self.mem_len]);
        }
    }
};

comptime {
    assert(@sizeOf(PoolSlice) == 8);
    assert(@alignOf(UrlBlock) >= @alignOf(URLSearchParamsData));
}
```

In `URLSearchParamsData`: **replace `owned: bool = true` with `block: ?*UrlBlock = null`**
(null = standalone `new URLSearchParams()`).

## 2) Zero-alloc pool writer + component decoder

```zig
const PoolWriter = struct {
    pool: []u8,
    used: usize = 0,
    fn rest(self: *PoolWriter) []u8 { return self.pool[self.used..]; }
    fn mark(self: *PoolWriter) usize { return self.used; }
    fn sliceFrom(self: *PoolWriter, off: usize) []const u8 {
        return self.pool[off..][0 .. self.used - off];
    }
    fn put(self: *PoolWriter, bytes: []const u8) []const u8 {
        if (bytes.len == 0) return "";
        const off = self.used;
        @memcpy(self.pool[off..][0..bytes.len], bytes);
        self.used += bytes.len;
        return self.pool[off..][0..bytes.len];
    }
    fn putUint(self: *PoolWriter, v: u16) void {
        var buf: [5]u8 = undefined;
        var n: usize = 0;
        var x = v;
        if (x == 0) { self.pool[self.used] = '0'; self.used += 1; return; }
        while (x > 0) : (x /= 10) { buf[n] = @intCast('0' + x % 10); n += 1; }
        while (n > 0) { n -= 1; self.pool[self.used] = buf[n]; self.used += 1; }
    }
    /// Decode-while-writing — same result as Component.toRawMaybeAlloc, no alloc.
    fn putComponent(self: *PoolWriter, comp: std.Uri.Component) []const u8 {
        switch (comp) {
            .raw => |raw| return self.put(raw),
            .percent_encoded => |pe| {
                const off = self.used;
                var i: usize = 0;
                while (i < pe.len) {
                    if (pe[i] == '%' and i + 2 < pe.len) {
                        if (std.fmt.parseInt(u8, pe[i + 1 .. i + 3], 16)) |byte| {
                            self.pool[self.used] = byte;
                            self.used += 1;
                            i += 3;
                            continue;
                        } else |_| {}
                    }
                    self.pool[self.used] = pe[i];
                    self.used += 1;
                    i += 1;
                }
                return self.pool[off..][0 .. self.used - off];
            },
        }
    }
};
```

## 3) Path helpers → write-into-buffer versions (mechanical ports)

```zig
fn removeDotSegmentsInto(out: []u8, input: []const u8) !usize {
    var n: usize = 0;
    var rest = input;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
        } else if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "/../")) {
            rest = rest[4..];
            while (n > 0) {
                n -= 1;
                if (n > 0 and out[n - 1] == '/') break;
                if (n == 0) break;
            }
            out[n] = '/';
            n += 1;
        } else if (std.mem.eql(u8, rest, "/..")) {
            rest = "";
            while (n > 0) {
                n -= 1;
                if (n > 0 and out[n - 1] == '/') break;
                if (n == 0) break;
            }
            out[n] = '/';
            n += 1;
        } else if (std.mem.startsWith(u8, rest, "/./")) {
            rest = rest[2..];
        } else if (std.mem.eql(u8, rest, "..")) {
            rest = "";
            out[n] = '/';
            n += 1;
        } else if (std.mem.eql(u8, rest, ".")) {
            rest = "";
        } else if (rest[0] == '/') {
            out[n] = '/';
            n += 1;
            rest = rest[1..];
        } else {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            @memcpy(out[n..][0..slash], rest[0..slash]);
            n += slash;
            rest = if (slash < rest.len) rest[slash..] else "";
        }
    }
    if (n == 0) { out[n] = '/'; n += 1; }
    return n;
}

fn mergePathsInto(out: []u8, base_path: []const u8, rel_path: []const u8) usize {
    var n: usize = 0;
    @memcpy(out[n..][0..base_path.len], base_path);
    n += base_path.len;
    if (std.mem.lastIndexOfScalar(u8, out[0..n], '/')) |idx| {
        n = idx + 1;
    } else {
        n = 0;
    }
    @memcpy(out[n..][0..rel_path.len], rel_path);
    n += rel_path.len;
    return n;
}
```
(`removeDotSegments`/`mergePaths` ArrayList versions: delete.)

## 4) Derived strings, written at parse time (replaces the 4 transient builders)

```zig
fn appendPort(url: *UrlData, w: *PoolWriter) void {
    const p = url.port orelse return;
    if (defaultPortForScheme(url.scheme)) |dp| { if (p == dp) return; }
    _ = w.put(":");
    w.putUint(p);
}

fn deriveStrings(url: *UrlData, w: *PoolWriter) void {
    // search / hash (keep leading ? / #, matching the old searchStr/hashStr)
    var m = w.mark();
    _ = w.put("?");
    _ = w.put(url.query);
    url.search = w.sliceFrom(m);
    m = w.mark();
    _ = w.put("#");
    _ = w.put(url.fragment);
    url.hash = w.sliceFrom(m);
    // host_str: host[:port]
    m = w.mark();
    _ = w.put(url.host);
    appendPort(url, w);
    url.host_str = w.sliceFrom(m);
    // port_str
    if (url.port != null and blk: {
        const dp = defaultPortForScheme(url.scheme) orelse break :blk true;
        break :blk url.port.? != dp;
    }) {
        m = w.mark();
        w.putUint(url.port.?);
        url.port_str = w.sliceFrom(m);
    }
    // origin: "null" for file/non-special, else scheme://host_str
    if (std.mem.eql(u8, url.scheme, "file") or !isSpecialScheme(url.scheme)) {
        url.origin = w.put("null");
    } else {
        m = w.mark();
        _ = w.put(url.scheme);
        _ = w.put("://");
        _ = w.put(url.host_str);
        url.origin = w.sliceFrom(m);
    }
    // href: scheme://[user[:pass]@]host_str path search hash
    m = w.mark();
    _ = w.put(url.scheme);
    _ = w.put("://");
    if (url.username.len > 0 or url.password.len > 0) {
        _ = w.put(url.username);
        if (url.password.len > 0) { _ = w.put(":"); _ = w.put(url.password); }
        _ = w.put("@");
    }
    _ = w.put(url.host_str);
    _ = w.put(url.path);
    _ = w.put(url.search);
    _ = w.put(url.hash);
    url.href = w.sliceFrom(m);
}
```
(Old `serialize`, `originStr`, `hostStr`, `searchStr`, `hashStr`, `portStr`: **delete.**
`urlToString`/`urlToJSON` become `return zigStringToJS(ctx, data.href);` — zero alloc per call.
`protocolStr` keeps its stack `bufPrint` — already alloc-free.)

## 5) Rewritten parsers (the UAF fix is inherent — nothing aliases the input)

```zig
fn parseUrlAbsolute(input: []const u8) !*UrlBlock {
    const uri = try std.Uri.parse(input);
    const block = try UrlBlock.create(input.len + 256); // upper bound: every
    errdefer block.release();                          // decoded component is a
    var w = PoolWriter{ .pool = block.poolSlice() };   // sub-slice of input
    const url = &block.url;
    url.port = uri.port;
    url.scheme = w.put(uri.scheme);
    url.host = if (uri.host) |h| w.putComponent(h) else "";
    url.path = blk: {
        if (uri.path.isEmpty()) break :blk w.put("/");
        const raw = w.putComponent(uri.path);          // decoded copy in pool
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), raw);
        break :blk w.pool[off..][0 .. w.used - off];
    };
    url.query = if (uri.query) |q| w.putComponent(q) else "";
    url.fragment = if (uri.fragment) |f| w.putComponent(f) else "";
    url.username = if (uri.user) |u| w.putComponent(u) else "";
    url.password = if (uri.password) |p| w.putComponent(p) else "";
    block.sp.parseFromString(url.query);
    deriveStrings(url, &w);
    return block;
}
```

```zig
fn parseUrlRelative(input: []const u8, base_url: []const u8) !*UrlBlock {
    const base = try std.Uri.parse(base_url);
    const block = try UrlBlock.create(input.len + base_url.len + 256);
    errdefer block.release();
    var w = PoolWriter{ .pool = block.poolSlice() };
    const url = &block.url;
    if (std.Uri.parse(input)) |rel| {
        if (rel.scheme.len > 0) {
            url.port = rel.port;
            url.scheme = w.put(rel.scheme);
            url.host = if (rel.host) |h| w.putComponent(h) else "";
            url.path = if (rel.path.isEmpty()) w.put("/") else blk: {
                const raw = w.putComponent(rel.path);
                const off = w.used;
                w.used += try removeDotSegmentsInto(w.rest(), raw);
                break :blk w.pool[off..][0 .. w.used - off];
            };
            url.query = if (rel.query) |q| w.putComponent(q) else "";
            url.fragment = if (rel.fragment) |f| w.putComponent(f) else "";
            url.username = if (rel.user) |u| w.putComponent(u) else "";
            url.password = if (rel.password) |p| w.putComponent(p) else "";
            block.sp.parseFromString(url.query);
            deriveStrings(url, &w);
            return block;
        }
        if (rel.host) |h| {
            url.port = rel.port;
            url.scheme = w.put(base.scheme);
            url.host = w.putComponent(h);
            url.path = if (rel.path.isEmpty()) w.put("/") else blk: {
                const raw = w.putComponent(rel.path);
                const off = w.used;
                w.used += try removeDotSegmentsInto(w.rest(), raw);
                break :blk w.pool[off..][0 .. w.used - off];
            };
            url.query = if (rel.query) |q| w.putComponent(q) else "";
            url.fragment = if (rel.fragment) |f| w.putComponent(f) else "";
            block.sp.parseFromString(url.query);
            deriveStrings(url, &w);
            return block;
        }
    } else |_| {}
    // pure-relative: merge onto the base path
    url.port = base.port;
    url.scheme = w.put(base.scheme);
    url.host = if (base.host) |h| w.putComponent(h) else "";
    const base_path = w.putComponent(base.path);
    url.username = if (base.user) |u| w.putComponent(u) else "";
    url.password = if (base.password) |p| w.putComponent(p) else "";
    const rel_path = input;
    if (rel_path.len == 0) {
        url.path = w.put(base_path);
        url.query = if (base.query) |q| w.putComponent(q) else "";
    } else if (rel_path[0] == '?') {
        url.path = w.put(base_path);
        url.query = w.put(rel_path[1..]);
    } else if (rel_path[0] == '#') {
        url.path = w.put(base_path);
        url.query = if (base.query) |q| w.putComponent(q) else "";
        url.hash = w.put(rel_path[1..]); // derived below with leading '#'
        const m = w.mark();
        _ = w.put("#");
        _ = w.put(url.hash);
        url.hash = w.sliceFrom(m);
    } else if (rel_path[0] == '/') {
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), rel_path);
        url.path = w.pool[off..][0 .. w.used - off];
        url.query = "";
    } else {
        var tmp: [4096]u8 = undefined; // merge scratch: base+rel bounded by pool math
        const n = mergePathsInto(&tmp, base_path, rel_path);
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), tmp[0..n]);
        url.path = w.pool[off..][0 .. w.used - off];
        url.query = "";
    }
    block.sp.parseFromString(url.query);
    deriveStrings(url, &w);
    return block;
}
```
Note: `url.hash` for the '#' branch is finalized inside `deriveStrings` (leading '#');
drop the two inline re-write lines if you prefer and let `deriveStrings` handle it
(both are equivalent — keep exactly one).

## 6) Finalizers + call-site updates (all in url.zig)

```zig
fn urlFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, url_class_id)) |ptr| {
        const data: *UrlData = @ptrCast(@alignCast(ptr));
        data.block.release(); // sp data is owned by the block now
    }
}

fn spFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, sp_class_id)) |ptr| {
        const data: *URLSearchParamsData = @ptrCast(@alignCast(ptr));
        if (data.block) |b| b.release() // embedded in a URL block
        else {
            data.deinit();
            gpa.destroy(data);
        }
    }
}
```

- `urlConstructor`: `const block = try (if (base) |b| parseUrlRelative(...) else parseUrlAbsolute(...)); const data: *UrlData = &block.url;`
  … then property definitions read `data.href`, `data.origin`, `data.host_str`, `data.search`, `data.hash`, `data.port_str` — no function calls, no allocs.
  `searchParams`: `block.sp.block = block; block.retain(); const sp_obj = createSPJsObject(ctx, &block.sp);`
- `createUrlJsObject` + `urlParseStatic`/`urlCanParseStatic`: same pattern (parse → block → `&block.url`); delete `data.search_params.owned = false` (line ~764).
- `extractUrlData` / `extractSPData` / all getters: unchanged (fields are still slices).
- Standalone `spConstructor`: unchanged (`gpa.create`, `block = null`) — `spFinalizer` frees it as today.
- Grep-check after edits: `search_params`, `.owned`, `serialize(`, `originStr`, `hostStr(`, `searchStr(`, `hashStr`, `portStr` → zero hits in url.zig.

## 7) Verification (measure, per the skill)

```sh
make build
cd bench && ../zig-out/bin/ff api_micro.js   # record new URL µs/op vs 2.15 baseline
../zig-out/bin/ff url.js                     # examples/url.js
cd .. && ./zig-out/bin/ff examples/async_handler.js   # 5 routes green
./wrk.sh                                     # server regression
ff -e 'const u=new URL("https://user:pw@example.com:8080/a/b?q=1#f");console.log(u.href,u.origin,u.host,u.pathname,u.search,u.hash,u.searchParams.get("q"))'
```
Expected: `new URL` well under 2.15 µs/op (≈1 alloc vs ~12), identical observable output,
no crashes under the 20k-iteration bench loop (the old code corrupted the heap by run 20k).
