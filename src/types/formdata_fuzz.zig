const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const formdata = @import("formdata.zig");

// FormData body parser (urlencoded + multipart) & CRUD fuzzer.

pub const events_smoke: usize = 15_000;
pub const events_default: ?usize = null;

const Op = enum { urlencoded, multipart, unsupported_ct, crud_ops };

const urlenc_tokens = [_][]const u8{
    "a=1", "b=hello+world%21", "flag", "%ZZ", "%2F%20", "&", "=", "", "x=",
};

const mp_ct_dict = [_][]const u8{
    "multipart/form-data; boundary=bnd",
    "multipart/form-data; charset=utf-8; boundary=\"bnd\"",
    "multipart/form-data",
    "multipart/form-data; boundary=",
    "multipart/form-data; foo=bar",
};

const keys = [_][]const u8{ "alpha", "beta", "file", "k", "" };

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 4);
    comptime assert(4 == @typeInfo(Op).@"enum".fields.len);

    var buf: [512]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;

        var fd = formdata.FormData.init();
        defer fd.deinit();

        switch (op) {
            .urlencoded => {
                const body: []const u8 = if (rand.float(f64) < 0.4)
                    fuzz.randomSlice(rand, &buf)
                else blk: {
                    var pos: usize = 0;
                    const n = rand.intRangeAtMost(usize, 0, 6);
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        pos = fuzz.appendTrunc(&buf, pos, fuzz.pick(rand, []const u8, &urlenc_tokens));
                    }
                    break :blk buf[0..pos];
                };
                assert(formdata.parseBody(&fd, "application/x-www-form-urlencoded", body));
                checkInvariants(&fd);
            },
            .multipart => {
                const ct = fuzz.pick(rand, []const u8, &mp_ct_dict);
                const body: []const u8 = if (rand.float(f64) < 0.4)
                    fuzz.randomSlice(rand, &buf)
                else
                    buildMultipart(rand, &buf);
                if (body.len == 0) {
                    assert(formdata.parseBody(&fd, ct, body));
                } else {
                    _ = formdata.parseBody(&fd, ct, body);
                }
                checkInvariants(&fd);
            },
            .unsupported_ct => {
                const body = fuzz.randomSlice(rand, &buf);
                const ok = formdata.parseBody(&fd, "application/json", body);
                if (body.len == 0) assert(ok) else assert(!ok);
            },
            .crud_ops => {
                const ops_n = rand.intRangeAtMost(usize, 1, 8);
                var i: usize = 0;
                while (i < ops_n) : (i += 1) {
                    const k = fuzz.pick(rand, []const u8, &keys);
                    const v = fuzz.randomSlice(rand, buf[0..64]);
                    switch (rand.intRangeLessThan(u8, 0, 4)) {
                        0 => fd.appendText(k, v),
                        1 => fd.appendFile(k, v, "f.bin", "Text/Plain ; charset=utf-8"),
                        2 => fd.setText(k, v),
                        else => fd.deleteAll(k),
                    }
                }
                checkInvariants(&fd);
            },
        }
    }
}

fn buildMultipart(rand: std.Random, buf: *[512]u8) []const u8 {
    const parts = [_][]const u8{
        "preamble\r\n",
        "--bnd\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n",
        "Content-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\nContent-Type: text/plain\r\n\r\ndata\r\n",
        "Content-Disposition: form-data\r\n\r\nno-name\r\n",
        "malformed-no-headers",
        "--bnd--\r\n",
    };
    var pos: usize = 0;
    const n = rand.intRangeAtMost(usize, 1, 6);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (rand.float(f64) < 0.2) {
            var tmp: [32]u8 = undefined;
            pos = fuzz.appendTrunc(buf, pos, fuzz.randomSlice(rand, &tmp));
        } else {
            pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &parts));
        }
    }
    return buf[0..pos];
}

fn checkInvariants(fd: *const formdata.FormData) void {
    assert(fd.len() == fd.entries.items.len);
    for (fd.entries.items) |e| {
        const nm = fd.nameOf(e);
        const vl = fd.valueOf(e);
        assert(nm.len <= fd.pool.items.len);
        assert(vl.len <= fd.pool.items.len);
    }
}
