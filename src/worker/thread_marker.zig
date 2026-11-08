const std = @import("std");

threadlocal var is_worker: bool = false;

pub fn isWorkerThread() bool {
    return is_worker;
}

pub fn setWorkerThread(v: bool) void {
    is_worker = v;
}
