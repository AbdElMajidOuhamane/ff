const std = @import("std");

threadlocal var is_worker: bool = false;

pub fn isWorkerThread() bool {
    return is_worker;
}

pub fn setWorkerThread(v: bool) void {
    is_worker = v;
}

test "worker thread marker toggles thread-local flag cleanly" {
    const prev = isWorkerThread();
    defer setWorkerThread(prev);

    setWorkerThread(false);
    try std.testing.expect(!isWorkerThread());
    setWorkerThread(true);
    try std.testing.expect(isWorkerThread());
    setWorkerThread(false);
    try std.testing.expect(!isWorkerThread());
}
