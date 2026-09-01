# Plan: Async server handlers + response headers from JS — full code

## Root causes (verified in source)

1. `http_native.zig:501` — `getTag(result) == 7` never matches: vendored quickjs-ng has
   `JS_TAG_OBJECT = -1` (7 = SHORT_BIG_INT). Async handlers silently return an empty 200.
2. `async_fetch.zig:501` / `ws_client.zig:630` — `asyncCb` never drains; `arm()` is only
   called from `runWithMicrotasks` (file mode), so `await fetch()` never resolves in
   `ff start` mode, and notify can be lost after a disarm→submit race.
3. Slot reuse hazard for late promise reactions → generation counter.

---

## 1) `src/engine/engine.zig`

Add imports (top, next to the other api/net imports):

```zig
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");
```

In `Runtime.init`, right after `EventLoop.initInto(loop_ptr);` (engine.zig:86), add:

```zig
        // Arm completion pumps before any user code runs so `ff start`
        // (.until_done mode, no polling) drains fetch/ws results too.
        // Idempotent; runWithMicrotasks re-arms as needed in file mode.
        async_fetch.arm(&loop_ptr.loop);
        ws_client.arm(&loop_ptr.loop);
```

---

## 2) `src/net/async_fetch.zig`

Add import:

```zig
const microtasks = @import("../event/microtasks.zig");
```

Add globals (next to `var async_armed = false;`, line ~57):

```zig
var g_ctx: ?*c.Context = null;
var g_loop: ?*xev.Loop = null;
```

Replace `init` (line 127) — takes ctx now:

```zig
pub fn init(ctx: ?*c.Context) void {
    g_ctx = ctx;
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
    ring_head = 0;
    ring_tail = 0;
    shutdown_requested = false;
    makeJobPipe() catch {
        async_h.deinit();
        return;
    };
    for (&worker_threads) |*t| {
            t.* = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerLoop, .{}) catch {
            t.* = null;
            break;
        };
    }
    pool_started = true;
}
```

Replace `arm` (line 495) and `asyncCb` (line 501), add `ensureArmed`:

```zig
pub fn arm(loop: *xev.Loop) void {
    if (async_armed) return;
    async_armed = true;
    g_loop = loop;
    async_h.wait(loop, &async_comp, void, null, asyncCb);
}

/// Re-arm after a disarm→submit sequence (single main thread: no race).
pub fn ensureArmed() void {
    if (async_armed) return;
    if (g_loop) |l| arm(l);
}

fn asyncCb(
    ud: ?*void,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: AsyncT.WaitError!void,
) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        // Run reaction jobs: resolves user promises (and resumes parked
        // HTTP handler continuations) on the main thread.
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
    } else {
        async_armed = false;
    }
    return .disarm;
}
```

At the very end of `submit` (line ~248, after the final `std.c.write` job-pipe wake), add:

```zig
    ensureArmed();
```

`src/api/fetch.zig:224` — change `async_fetch.init();` to `async_fetch.init(ctx);`.

---

## 3) `src/net/ws_client.zig` (same pattern)

Add import:

```zig
const microtasks = @import("../event/microtasks.zig");
```

Add globals (next to `var async_armed = false;`, line 88):

```zig
var g_ctx: ?*c.Context = null;
var g_loop: ?*xev.Loop = null;
```

Replace `init` (line 125):

```zig
pub fn init(ctx: ?*c.Context) void {
    g_ctx = ctx;
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
}
```

Replace `arm`/`asyncCb` (lines 625-646), add `ensureArmed`:

```zig
pub fn arm(l: *xev.Loop) void {
    if (async_armed) return;
    async_armed = true;
    g_loop = l;
    async_h.wait(l, &async_comp, void, null, asyncCb);
}

pub fn ensureArmed() void {
    if (async_armed) return;
    if (g_loop) |l| arm(l);
}

fn asyncCb(
    ud: ?*void,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: AsyncT.WaitError!void,
) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
    } else {
        async_armed = false;
    }
    return .disarm;
}
```

At the end of `submit` (line ~182, after `th.detach();`), add:

```zig
    ensureArmed();
```

`src/api/websocket_client.zig:89` — change `ws_client.init();` to `ws_client.init(ctx);`.

---

## 4) `src/types/response.zig` — expose native access for the server

Add after `extractResponseData` (line ~55):

```zig
/// Native accessor for the HTTP server: read status/body/headers from a
/// JS Response object without property lookups.
pub fn dataFromJS(ctx: ?*c.Context, val: c.Value) ?*ResponseData {
    if (c.isObject(val) == 0) return null;
    const ptr = c.getOpaque2(ctx, val, response_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}
```

---

## 5) `src/net/http_native.zig` — the core

### 5a) Imports (top, after `tls_mod`)

```zig
const response_mod = @import("../types/response.zig");
const headers_mod = @import("../types/headers.zig");
```

### 5b) `ConnFlags` — replace (line 26)

```zig
const ConnFlags = packed struct(u16) {
    keep_alive: bool = false,
    ws_open: bool = false,
    ws_writing: bool = false,
    ws_close_after_write: bool = false,
    ws_read_armed: bool = false,
    ws_pending_open: bool = false,
    tls: bool = false,
    handler_parked: bool = false,
    _pad: u7 = 0,
};
```

### 5c) New slot columns + watchdog globals (after `var slot_ids`, line 82)

```zig
// ── Parked async handlers (one flat column per slot) ──
// Generation counter guards late promise reactions against slot reuse.
var slot_gen: [MAX_CONN]u16 = [_]u16{0} ** MAX_CONN;
var parked_since_ms: [MAX_CONN]u64 = [_]u64{0} ** MAX_CONN;
var promise_class_id: c.ClassID = 0;

const HDR_MAX = 2048;
const HANDLER_TIMEOUT_MS: u64 = 30_000;
const WATCHDOG_INTERVAL_MS: u64 = 1000;
var watchdog_timer: xev.Timer = undefined;
var watchdog_comp: xev.Completion = .{};
var watchdog_started = false;
```

### 5d) Promise class probe — replace `setupStrings` (line 1327)

```zig
pub fn setupStrings(ctx: ?*c.Context) void {
    // One-time probe: capture QuickJS's internal Promise class id so
    // callHandler detects promises with a single JS_GetClassID call
    // (zero per-request property lookups).
    if (promise_class_id != 0) return;
    var cap: [2]c.Value = undefined;
    const p = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, p);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    if (c.isObject(p) != 0) promise_class_id = c.getClassID(p);
}
```

### 5e) Helpers — add after `extractInt` (line ~452)

```zig
fn nowMs() u64 {
    return @intCast(@max(std.time.milliTimestamp(), 0));
}

fn isManagedHeader(name: []const u8) bool {
    // Length/ hop-by-hop framing is computed by the server, never taken from JS.
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

fn printException(ctx: ?*c.Context, exc: c.Value) void {
    const msg = c.toCString(ctx, exc) orelse return;
    defer c.freeCString(ctx, msg);
    std.debug.print("[http] handler error: {s}\n", .{msg});
}

fn logAllocs(id: usize) void {
    if (builtin.mode != .Debug) return;
    std.debug.print(
        "[allocs] req id={d}: allocs={d} frees={d} +{d}B -{d}B balanced={}\n",
        .{
            id,
            req_counter.alloc_count,
            req_counter.free_count,
            req_counter.bytes_allocated,
            req_counter.bytes_freed,
            req_counter.balanced(),
        },
    );
    std.debug.assert(req_counter.balanced());
}
```

### 5f) Replace `stageLargeResponse` (line 456) — staging assumes the header is
###     already formatted in `write_bufs[id]`

```zig
/// Stage a large response body for chunked draining. The caller has already
/// formatted the header block into write_bufs[id] (write_lens[id] = header
/// length); writeCb loads WRITE_BUF_SIZE chunks from body_bufs afterwards.
fn stageLargeResponse(id: usize, header_len: usize, body_ptr: [*]const u8, blen: usize) void {
    write_lens[id] = header_len;
    write_offsets[id] = 0;
    @memcpy(body_bufs[id][0..blen], body_ptr[0..blen]);
    body_lens[id] = blen;
    body_remaining[id] = blen;
    body_source_off[id] = 0;
}
```

### 5g) New: `stageHandlerResponse` — add after `stageLargeResponse`

Shared by the sync path and the parked-continuation callback. Reads `Response`
objects natively (opaque pointer → no JS property lookups), plain objects via
properties (back-compat). Serializes user headers straight into `write_bufs`
— zero dynamic allocations.

```zig
fn stageHandlerResponse(id: usize, result: c.Value) void {
    const ctx = handler_ctx orelse {
        buildResponse(id, 500, "Internal Server Error");
        return;
    };

    var status: u16 = 200;
    var status_text: []const u8 = "";
    var body_bytes: []const u8 = "";
    var has_body = false;
    var hdrs: ?*headers_mod.HeadersData = null;

    if (c.isObject(result) != 0) {
        if (response_mod.dataFromJS(ctx, result)) |rd| {
            status = rd.status;
            status_text = rd.statusText();
            if (rd.body()) |b| {
                body_bytes = b;
                has_body = true;
            }
            hdrs = &rd.headers;
        } else {
            // Plain JS object fallback: { status, body }.
            const status_val = c.getPropertyStr(ctx, result, "status");
            defer c.freeValue(ctx, status_val);
            status = extractInt(ctx, status_val, 200);
            const body_out_val = c.getPropertyStr(ctx, result, "body");
            defer c.freeValue(ctx, body_out_val);
            if (c.isString(body_out_val) != 0) {
                if (c.toCString(ctx, body_out_val)) |cstr| {
                    defer c.freeCString(ctx, cstr);
                    const n = std.mem.len(cstr);
                    if (n > 0) {
                        body_bytes = cstr[0..n];
                        has_body = true;
                    }
                }
            } else if (c.isObject(body_out_val) != 0) {
                var size: usize = 0;
                const p = c.getArrayBuffer(ctx, &size, body_out_val);
                if (p != null and size > 0) {
                    body_bytes = p.?[0..size];
                    has_body = true;
                }
            }
        }
    }

    const suppress = !wantsBodyBytes(id, status);
    if (has_body and !suppress and body_bytes.len > BODY_BUF_SIZE) {
        buildResponse(id, 500, "response body too large");
        return;
    }

    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos: usize = 0;

    // Status line.
    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    if (status_text.len > 0 and std.mem.indexOfAny(u8, status_text, "\r\n") == null) {
        pushStr(w, &pos, status_text);
    } else {
        pushStr(w, &pos, statusReason(status));
    }
    pushStr(w, &pos, "\r\n");

    // User headers from the Response's HeadersData (already lowercased).
    // Drop CR/LF-bearing pairs (header-injection guard).
    var seen_ct = false;
    if (hdrs) |h| {
        for (0..h.len()) |i| {
            const p = h.getPair(i);
            if (isManagedHeader(p.name)) continue;
            if (std.mem.indexOfAny(u8, p.name, "\r\n") != null or
                std.mem.indexOfAny(u8, p.value, "\r\n") != null) continue;
            if (std.ascii.eqlIgnoreCase(p.name, "content-type")) seen_ct = true;
            if (pos + p.name.len + p.value.len + 4 > HDR_MAX) break; // budget: drop the rest
            pushStr(w, &pos, p.name);
            pushStr(w, &pos, ": ");
            pushStr(w, &pos, p.value);
            pushStr(w, &pos, "\r\n");
        }
    }
    // Back-compat default content type only when JS gave none.
    if (!seen_ct and has_body and !suppress) {
        pushStr(w, &pos, "Content-Type: text/plain\r\n");
    }
    if (status != 204 and status != 304) {
        pushStr(w, &pos, "Content-Length: ");
        appendUInt(w, &pos, body_bytes.len);
        pushStr(w, &pos, "\r\n");
    }
    if (cflags[id].keep_alive) pushStr(w, &pos, "Connection: keep-alive\r\n");
    pushStr(w, &pos, "\r\n");

    write_lens[id] = pos;
    write_offsets[id] = 0;
    body_lens[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;

    if (suppress or !has_body or body_bytes.len == 0) return;

    if (pos + body_bytes.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body_bytes.len], body_bytes);
        write_lens[id] = pos + body_bytes.len;
    } else {
        stageLargeResponse(id, pos, body_bytes.ptr, body_bytes.len);
    }
}
```

### 5h) New: parking machinery — add after `stageHandlerResponse`

```zig
/// Claim a parked slot from a reaction's packed magic. Returns null when the
/// connection was closed or the slot was reused (generation mismatch).
fn claimParkedSlot(magic: c_int) ?usize {
    const m: u32 = @bitCast(magic);
    const id: usize = @intCast(m & 0xFFFF);
    const gen: u16 = @intCast((m >> 16) & 0xFFFF);
    if (id >= MAX_CONN) return null;
    if (slot_gen[id] != gen) return null;
    if (!cflags[id].handler_parked) return null;
    return id;
}

fn completeParked(magic: c_int, argc: c_int, argv: [*c]c.Value, rejected: bool) c.Value {
    const id = claimParkedSlot(magic) orelse return c.JS_UNDEFINED;
    cflags[id].handler_parked = false;
    parked_since_ms[id] = 0;

    const val: c.Value = if (argc > 0) argv[0] else c.JS_UNDEFINED;
    if (rejected) {
        printException(handler_ctx, val);
        buildResponse(id, 500, "Internal Server Error");
    } else {
        stageHandlerResponse(id, val);
    }
    if (g_loop) |l| {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        closeConn(id);
    }
    return c.JS_UNDEFINED;
}

fn handlerFulfilledCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, false);
}

fn handlerRejectedCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, true);
}

/// Attach onFulfilled/onRejected to a pending handler promise. Zero
/// allocations on the Zig side: the slot id + generation travel in the
/// C-function magic (i32), continuations live in the slot columns.
fn parkHandler(id: usize, ctx: ?*c.Context, promise: c.Value) bool {
    const magic: i32 = @bitCast(@as(u32, @intCast(id)) | (@as(u32, slot_gen[id]) << 16));
    const ok_fn = c.newCFunctionMagic(ctx, &handlerFulfilledCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    const err_fn = c.newCFunctionMagic(ctx, &handlerRejectedCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    defer c.freeValue(ctx, ok_fn);
    defer c.freeValue(ctx, err_fn);
    if (c.isException(ok_fn) != 0 or c.isException(err_fn) != 0) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
        return false;
    }
    const then_atom = c.newAtomLen(ctx, "then", 4);
    defer c.freeAtom(ctx, then_atom);
    var then_argv = [_]c.Value{ ok_fn, err_fn };
    const then_result = c.invoke(ctx, promise, then_atom, 2, &then_argv);
    defer c.freeValue(ctx, then_result);
    if (c.isException(then_result) != 0) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
        return false;
    }
    cflags[id].handler_parked = true;
    parked_since_ms[id] = nowMs();
    return true;
}
```

### 5i) Replace `callHandler` (line 472) — removes the dead tag==7 spin

```zig
fn callHandler(id: usize, parsed: *const ParsedRequest, body: []const u8) void {
    if (builtin.mode == .Debug) req_counter.reset();
    const ctx = handler_ctx orelse {
        buildResponse(id, 500, "");
        return;
    };
    const handler = handler_fn orelse {
        buildResponse(id, 500, "");
        return;
    };
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const url_val = c.newStringLen(ctx, parsed.url.ptr, @intCast(parsed.url.len));
    const method_val = c.newStringLen(ctx, parsed.method.ptr, @intCast(parsed.method.len));
    const body_val = if (body.len > 0)
        c.newStringLen(ctx, body.ptr, @intCast(body.len))
    else
        c.newStringLen(ctx, "", 0);
    defer c.freeValue(ctx, url_val);
    defer c.freeValue(ctx, method_val);
    defer c.freeValue(ctx, body_val);

    var argv = [_]c.Value{ url_val, method_val, body_val };
    var result = c.call(ctx, handler, global, 3, &argv);
    defer c.freeValue(ctx, result);

    if (c.isException(result) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        buildResponse(id, 500, "Internal Server Error");
        logAllocs(id);
        return;
    }

    if (promise_class_id != 0 and c.isObject(result) != 0 and
        c.getClassID(result) == promise_class_id)
    {
        const ps = c.promiseState(ctx, result);
        if (ps == 0) {
            // Pending: park the connection; the promise's `then` reactions
            // resume staging + writing from the event loop (or watchdog).
            if (parkHandler(id, ctx, result)) {
                if (builtin.mode == .Debug)
                    std.debug.print("[allocs] req id={d}: parked\n", .{id});
                return;
            }
            buildResponse(id, 500, "Internal Server Error");
            logAllocs(id);
            return;
        }
        if (ps == 2) {
            // Rejected.
            const pr = c.promiseResult(ctx, result);
            c.freeValue(ctx, result);
            result = pr;
            printException(ctx, pr);
            buildResponse(id, 500, "Internal Server Error");
            logAllocs(id);
            return;
        }
        // Fulfilled synchronously: unwrap and stage without an event-loop
        // roundtrip (keeps the hot path allocation-free and fast).
        const pr = c.promiseResult(ctx, result);
        c.freeValue(ctx, result);
        result = pr;
    }

    stageHandlerResponse(id, result);
    logAllocs(id);
}
```

### 5j) `processPlaintext` (line 1020) — parked guard + conditional write arm

Add at the top of the function body:

```zig
    if (cflags[id].handler_parked) {
        // Parked: don't parse pipelined bytes; just watch for EOF and
        // buffer pressure while the handler's promise is pending.
        if (buf_lens[id] >= READ_BUF_SIZE) {
            closeConn(id);
            return;
        }
        armRead(id, l);
        return;
    }
```

And replace the tail (lines ~1064-1071):

```zig
    cflags[id].keep_alive = pr.keep_alive;
    if (native_echo) {
        buildResponse(id, 200, "{\"message\":\"ok\"}");
    } else {
        const body = read_bufs[id][headers_end .. headers_end + pr.content_length];
        callHandler(id, &pr, body);
    }
    if (!cflags[id].handler_parked) {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        // Keep reads armed while parked so a vanished client frees the slot.
        states[id] = .reading;
        armRead(id, l);
    }
```

### 5k) `setupSlot` (line 936) — bump generation, reset parked state

After `fds[id] = tcp;` add:

```zig
    slot_gen[id] +%= 1;
    cflags[id].handler_parked = false;
    parked_since_ms[id] = 0;
```

### 5l) `closeConn` (line 897) — invalidate any parked continuation

After `body_lens[id] = 0;` (line ~900) add:

```zig
    cflags[id].handler_parked = false;
    parked_since_ms[id] = 0;
```

### 5m) Watchdog — add after `closeCb` (line ~934)

```zig
/// One repeating timer (not from the 128-slot JS timer pool): scans parked
/// slots and fails hung handlers with 504.
fn watchdogCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const now = nowMs();
    for (0..MAX_CONN) |id| {
        if (!cflags[id].handler_parked) continue;
        if (now -% parked_since_ms[id] < HANDLER_TIMEOUT_MS) continue;
        cflags[id].handler_parked = false;
        parked_since_ms[id] = 0;
        buildResponse(id, 504, "Gateway Timeout");
        states[id] = .writing;
        armWrite(id, l);
    }
    watchdog_timer.run(l, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
    return .disarm;
}
```

In `init` (line 1275), after `listener_tcp.accept(...)` add:

```zig
    if (!watchdog_started) {
        watchdog_timer = xev.Timer.init() catch unreachable;
        watchdog_timer.run(loop, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
        watchdog_started = true;
    }
```

Note: the watchdog only starts when `http.serve` ran, so it never keeps a
server-less process alive; while a server runs, the listener already pins
the loop.

### 5n) `deinit` (line 1294) — optional hygiene

After the `ws_sockets` cleanup loop add nothing required (loop teardown drops
the timer completion), but for re-init safety set:

```zig
    watchdog_started = false;
```

---

## 6) `examples/async_handler.js` (new file)

```js
// Async handlers + response headers demo.
// Run:   ./zig-out/bin/ff examples/async_handler.js
// Test:  curl -i http://127.0.0.1:3001/api/time
//        curl -i http://127.0.0.1:3001/slow
//        curl -i http://127.0.0.1:3001/headers
//        curl -i http://127.0.0.1:3001/boom     (rejected promise -> 500)
//        curl -i -X POST -d 'hi' http://127.0.0.1:3001/echo

http.serve({ port: 3001 }, async (req) => {
    const url = new URL(req.url);

    if (url.pathname === "/api/time") {
        // Real await: yields to the event loop before responding.
        await new Promise((resolve) => setTimeout(resolve, 10));
        return Response.json({ ok: true, now: Date.now() });
    }

    if (url.pathname === "/slow") {
        await new Promise((resolve) => setTimeout(resolve, 100));
        return new Response("finally!", {
            status: 200,
            headers: { "content-type": "text/plain; charset=utf-8" },
        });
    }

    if (url.pathname === "/headers") {
        return new Response("multi header demo", {
            status: 200,
            headers: {
                "content-type": "text/plain; charset=utf-8",
                "x-engine": "fairyfly",
                "set-cookie": "a=1; Path=/",
            },
        });
    }

    if (url.pathname === "/boom") {
        throw new Error("boom");
    }

    return new Response("routes: /api/time /slow /headers /boom /echo");
});
```

---

## 7) README.md (minimal edits)

- In the **HTTP server** tutorial, after the existing example, add:

````markdown
Handlers can be `async` — the runtime parks the connection and resumes it
when the promise settles (no thread is blocked):

```js
http.serve({ port: 3000 }, async (req) => {
    const res = await fetch("https://example.com/api");
    const data = await res.json();
    return Response.json(data);
});
```

`Response` headers are sent verbatim (except `Content-Length`,
`Transfer-Encoding` and `Connection`, which the server computes). Header
blocks are capped at 2 KB; a hung handler is failed with 504 after 30 s.
````

- In **Limitations vs Node / browser**, remove/adjust the line claiming no
  custom response headers if present.

---

## 8) Verification checklist

```sh
zig build          # debug: watch "[allocs] req id=N: balanced=true"
make build         # ReleaseFast

# 1. async handlers (file mode)
./zig-out/bin/ff examples/async_handler.js &
curl -i http://127.0.0.1:3001/api/time     # JSON, after ~10ms
curl -i http://127.0.0.1:3001/slow         # "finally!" after ~100ms, text/plain; charset=utf-8
curl -i http://127.0.0.1:3001/headers      # x-engine + set-cookie present
curl -i http://127.0.0.1:3001/boom         # 500 + "[http] handler error: Error: boom" on stderr
curl -i http://127.0.0.1:3001/             # sync handler unchanged

# 2. hang watchdog
# (temporarily add a route that never resolves) -> 504 after 30s, slot freed

# 3. server mode (ff start) — await fetch inside handler must now resolve
cd examples/express-test && ../zig-out/bin/ff start   # or any ff.json project

# 4. regression: sync hot path
./wrk.sh            # expect ~138k req/s echo unchanged (echo path never parks)
./zig-out/bin/ff examples/server.js &   # existing examples still behave
```

Also confirm `tests/tls/server.js` (HTTPS + WSS) still round-trips.

## Out of scope (later)
Request-body streaming/chunked TE, AbortSignal, per-handler timeout config,
response streaming.
