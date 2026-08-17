const std = @import("std");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");

pub const MAX_IMMEDIATES = 128;
// Ids handed to JS are offset so they never collide with TimerManager's
// 0..MAX_TIMERS-1 space; clearTimeout/clearImmediate route by range.
pub const ID_OFFSET: usize = 1 << 10;

// In-process zero-delay queue: no kernel timers, no syscalls per item.
// setImmediate(fn) and setTimeout(fn, 0) -> alloc a slot + FIFO ring entry;
// the event loop calls flush() on the next tick (bun-style immediate list
// instead of a fresh xev Timer per call).
pub const ImmediateManager = struct {
    // SoA hot state
    active:      [MAX_IMMEDIATES]bool,
    isolate:     [MAX_IMMEDIATES]?*c.Isolate,
    persistent:  [MAX_IMMEDIATES]c.Global,

    // Singleton free-list
    free_head:  usize,
    next_free:  [MAX_IMMEDIATES]usize,

    // FIFO ring of active slot ids (clear() leaves a tombstone, skipped at
    // flush so ordering of still-live immediates is preserved)
    order:       [MAX_IMMEDIATES]usize,
    order_head:  usize,
    order_count: usize,

    pub fn init() ImmediateManager {
        var im: ImmediateManager = .{
            .active = [_]bool{false} ** MAX_IMMEDIATES,
            .isolate = [_]?*c.Isolate{null} ** MAX_IMMEDIATES,
            .persistent = undefined,
            .free_head = 0,
            .next_free = undefined,
            .order = undefined,
            .order_head = 0,
            .order_count = 0,
        };
        for (0..MAX_IMMEDIATES) |i| im.next_free[i] = i + 1;
        im.next_free[MAX_IMMEDIATES - 1] = MAX_IMMEDIATES;
        return im;
    }

    fn popFree(self: *ImmediateManager) ?usize {
        const head = self.free_head;
        if (head == MAX_IMMEDIATES) return null;
        self.free_head = self.next_free[head];
        return head;
    }

    fn pushFree(self: *ImmediateManager, idx: usize) void {
        self.next_free[idx] = self.free_head;
        self.free_head = idx;
    }

    pub fn pending(self: *const ImmediateManager) bool {
        return self.order_count != 0;
    }

    // Returns an encoded id (ID_OFFSET + slot) so the caller can route
    // clear by range without ambiguity with TimerManager ids.
    pub fn set(self: *ImmediateManager, isolate: ?*c.Isolate, callback: ?*const c.Value) !usize {
        const idx = self.popFree() orelse return error.NoSlotsAvailable;
        self.active[idx] = true;
        self.isolate[idx] = isolate;
        c.v8__Global__New(isolate, @ptrCast(callback), &self.persistent[idx]);
        const tail = (self.order_head + self.order_count) % MAX_IMMEDIATES;
        self.order[tail] = idx;
        self.order_count += 1;
        return idx + ID_OFFSET;
    }

    // id is an encoded id from set(); decoded internally.
    pub fn clear(self: *ImmediateManager, id: usize) void {
        if (id < ID_OFFSET or id >= ID_OFFSET + MAX_IMMEDIATES) return;
        const idx = id - ID_OFFSET;
        if (!self.active[idx]) return;
        self.active[idx] = false;
        self.isolate[idx] = null;
        c.v8__Global__Reset(&self.persistent[idx]);
        self.pushFree(idx);
    }

    pub fn cancelAll(self: *ImmediateManager) void {
        for (0..MAX_IMMEDIATES) |i| {
            if (self.active[i]) {
                self.active[i] = false;
                self.isolate[i] = null;
                c.v8__Global__Reset(&self.persistent[i]);
            }
        }
        self.order_head = 0;
        self.order_count = 0;
    }

    // Run every queued immediate once (FIFO, drain-to-empty like node), then
    // a single microtask pump so awaited continuations make progress.
    pub fn flush(self: *ImmediateManager, isolate: ?*c.Isolate) void {
        const iso = isolate orelse return;
        if (self.order_count == 0) return;

        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, iso);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);

        while (self.order_count != 0) {
            const idx = self.order[self.order_head];
            self.order_head = (self.order_head + 1) % MAX_IMMEDIATES;
            self.order_count -= 1;
            if (!self.active[idx]) continue; // cleared before flush
            self.active[idx] = false;
            self.isolate[idx] = null;

            if (c.v8__Global__Get(&self.persistent[idx], iso)) |val| {
                const context = c.v8__Isolate__GetCurrentContext(iso);
                const recv = c.v8__Undefined(iso);
                _ = c.v8__Function__Call(@ptrCast(val), context, @ptrCast(recv), 0, null);
            }
            c.v8__Global__Reset(&self.persistent[idx]);
            self.pushFree(idx);
        }
        microtasks.pumpMicrotasks(iso);
    }
};

// Module-global so the event loop can flush without a Runtime pointer
// (same pattern as the async_fetch global).
var g_manager: ImmediateManager = ImmediateManager.init();

pub fn init() void {
    g_manager = ImmediateManager.init();
}
pub fn set(isolate: ?*c.Isolate, callback: ?*const c.Value) !usize {
    return g_manager.set(isolate, callback);
}
pub fn clear(id: usize) void {
    g_manager.clear(id);
}
pub fn cancelAll() void {
    g_manager.cancelAll();
}
pub fn pending() bool {
    return g_manager.pending();
}
pub fn flush(isolate: ?*c.Isolate) void {
    g_manager.flush(isolate);
}
