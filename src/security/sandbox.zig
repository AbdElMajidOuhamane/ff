//! Linux runtime sandbox: Landlock LSM filesystem restriction + seccomp-bpf
//! syscall filter, applied once at startup *after* libxev initializes the
//! io_uring instance so `io_uring_enter` stays at full speed while
//! `io_uring_setup`, `io_uring_register`, and process-spawn/kernel-tamper
//! syscalls are blocked by the kernel.
//!
//! Zero heap allocation; fail-closed whenever `--simple-sandbox` is requested.

const std = @import("std");
const builtin = @import("builtin");
const perm = @import("permissions.zig");
const limits = @import("../util/limits.zig");
const cli = @import("../util/cli.zig");

pub const SandboxError = error{
    SandboxUnsupportedOnOs,
    SandboxUnsupportedArch,
    NoNewPrivsFailed,
    LandlockFailed,
    SeccompFailed,
};

// ── Classic BPF / seccomp structures ──────────────────────────────

pub const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

pub const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

comptime {
    std.debug.assert(@sizeOf(SockFilter) == 8);
    std.debug.assert(@offsetOf(SockFilter, "code") == 0);
    std.debug.assert(@offsetOf(SockFilter, "jt") == 2);
    std.debug.assert(@offsetOf(SockFilter, "jf") == 3);
    std.debug.assert(@offsetOf(SockFilter, "k") == 4);
    std.debug.assert(@sizeOf(SockFprog) == 16);
}

// BPF instruction constants (Linux <linux/filter.h>)
const BPF_LD: u16 = 0x00;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_JMP: u16 = 0x05;
const BPF_JEQ: u16 = 0x10;
const BPF_K: u16 = 0x00;
const BPF_RET: u16 = 0x06;

const BPF_LD_W_ABS: u16 = BPF_LD | BPF_W | BPF_ABS;
const BPF_JMP_JEQ_K: u16 = BPF_JMP | BPF_JEQ | BPF_K;
const BPF_RET_K: u16 = BPF_RET | BPF_K;

const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
const SECCOMP_RET_ERRNO_EPERM: u32 = 0x0005_0001; // SECCOMP_RET_ERRNO | EPERM(1)
const SECCOMP_RET_ALLOW: u32 = 0x7FFF_0000;

const SECCOMP_DATA_NR_OFFSET: u32 = 0;
const SECCOMP_DATA_ARCH_OFFSET: u32 = 4;

const AUDIT_ARCH_AARCH64: u32 = 0xC000_00B7;
const AUDIT_ARCH_X86_64: u32 = 0xC000_003E;

pub const MAX_BPF_INSNS: usize = 64;

fn blockedSyscallsForArch(comptime arch: std.Target.Cpu.Arch) ?[13]u32 {
    return switch (arch) {
        .aarch64 => .{
            425, // io_uring_setup
            427, // io_uring_register
            221, // execve
            281, // execveat
            117, // ptrace
            40, // mount
            39, // umount2
            280, // bpf
            219, // keyctl
            104, // kexec_load
            105, // init_module
            273, // finit_module
            106, // delete_module
        },
        .x86_64 => .{
            425, // io_uring_setup
            427, // io_uring_register
            59, // execve
            322, // execveat
            101, // ptrace
            165, // mount
            166, // umount2
            321, // bpf
            250, // keyctl
            246, // kexec_load
            175, // init_module
            313, // finit_module
            176, // delete_module
        },
        else => null,
    };
}

fn auditArchFor(comptime arch: std.Target.Cpu.Arch) ?u32 {
    return switch (arch) {
        .aarch64 => AUDIT_ARCH_AARCH64,
        .x86_64 => AUDIT_ARCH_X86_64,
        else => null,
    };
}

/// Builds a static seccomp-bpf program that blocks dangerous syscalls
/// (including `io_uring_setup` and `io_uring_register` after startup)
/// while keeping `io_uring_enter` (426) and normal I/O syscalls allowed.
pub fn buildSeccompProgram(
    comptime arch: std.Target.Cpu.Arch,
    out: *[MAX_BPF_INSNS]SockFilter,
) SandboxError!usize {
    const expected_arch = auditArchFor(arch) orelse return error.SandboxUnsupportedArch;
    const blocked = blockedSyscallsForArch(arch) orelse return error.SandboxUnsupportedArch;
    const m = blocked.len;
    const total_len = 4 + m + 2;
    comptime std.debug.assert(total_len <= MAX_BPF_INSNS);
    comptime std.debug.assert(m <= 255);

    // 0..2: validate seccomp_data.arch
    out[0] = .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = SECCOMP_DATA_ARCH_OFFSET };
    out[1] = .{ .code = BPF_JMP_JEQ_K, .jt = 1, .jf = 0, .k = expected_arch };
    out[2] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_KILL_PROCESS };
    // 3: load syscall number
    out[3] = .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = SECCOMP_DATA_NR_OFFSET };
    // 4..4+m-1: compare against each blocked syscall; match jumps to ret_deny (4 + m + 1)
    for (blocked, 0..) |nr, i| {
        const jump_to_deny: u8 = @intCast(m - i);
        out[4 + i] = .{ .code = BPF_JMP_JEQ_K, .jt = jump_to_deny, .jf = 0, .k = nr };
    }
    // 4+m: allow; 4+m+1: deny with EPERM
    out[4 + m] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ALLOW };
    out[4 + m + 1] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ERRNO_EPERM };
    return total_len;
}

// ── Landlock LSM UAPI (Linux 5.13+, ABI v1) ───────────────────────

pub const LandlockRulesetAttr = extern struct {
    handled_access_fs: u64,
};

// Linux UAPI `struct landlock_path_beneath_attr` uses `__attribute__((packed))`
// (size 12, no trailing padding after parent_fd).
pub const LandlockPathBeneathAttr = extern struct {
    allowed_access: u64 align(1),
    parent_fd: i32 align(1),
};

comptime {
    std.debug.assert(@sizeOf(LandlockRulesetAttr) == 8);
    std.debug.assert(@sizeOf(LandlockPathBeneathAttr) == 12);
    std.debug.assert(@offsetOf(LandlockPathBeneathAttr, "allowed_access") == 0);
    std.debug.assert(@offsetOf(LandlockPathBeneathAttr, "parent_fd") == 8);
}

const LANDLOCK_RULE_PATH_BENEATH: usize = 1;

const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;

const LANDLOCK_FILE_ACCESS_MASK: u64 =
    LANDLOCK_ACCESS_FS_EXECUTE |
    LANDLOCK_ACCESS_FS_WRITE_FILE |
    LANDLOCK_ACCESS_FS_READ_FILE;

const LANDLOCK_READ_FILE_ACCESS: u64 = LANDLOCK_ACCESS_FS_READ_FILE;
const LANDLOCK_READ_DIR_ACCESS: u64 =
    LANDLOCK_ACCESS_FS_READ_FILE |
    LANDLOCK_ACCESS_FS_READ_DIR;

const LANDLOCK_WRITE_FILE_ACCESS: u64 = LANDLOCK_ACCESS_FS_WRITE_FILE;
const LANDLOCK_WRITE_DIR_ACCESS: u64 =
    LANDLOCK_ACCESS_FS_WRITE_FILE |
    LANDLOCK_ACCESS_FS_REMOVE_DIR |
    LANDLOCK_ACCESS_FS_REMOVE_FILE |
    LANDLOCK_ACCESS_FS_MAKE_DIR |
    LANDLOCK_ACCESS_FS_MAKE_REG |
    LANDLOCK_ACCESS_FS_MAKE_SYM;

const LANDLOCK_HANDLED_ALL_V1: u64 =
    LANDLOCK_ACCESS_FS_EXECUTE |
    LANDLOCK_ACCESS_FS_WRITE_FILE |
    LANDLOCK_ACCESS_FS_READ_FILE |
    LANDLOCK_ACCESS_FS_READ_DIR |
    LANDLOCK_ACCESS_FS_REMOVE_DIR |
    LANDLOCK_ACCESS_FS_REMOVE_FILE |
    LANDLOCK_ACCESS_FS_MAKE_CHAR |
    LANDLOCK_ACCESS_FS_MAKE_DIR |
    LANDLOCK_ACCESS_FS_MAKE_REG |
    LANDLOCK_ACCESS_FS_MAKE_SOCK |
    LANDLOCK_ACCESS_FS_MAKE_FIFO |
    LANDLOCK_ACCESS_FS_MAKE_BLOCK |
    LANDLOCK_ACCESS_FS_MAKE_SYM;

fn addLandlockPath(ruleset_fd: i32, path: []const u8, dir_access: u64, file_access: u64) void {
    if (comptime builtin.os.tag != .linux) return;
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);

    var is_dir = true;
    var fd_rc = std.os.linux.open(path_z, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(fd_rc) != .SUCCESS) {
        is_dir = false;
        fd_rc = std.os.linux.open(path_z, .{ .PATH = true, .CLOEXEC = true }, 0);
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    const access = if (is_dir) dir_access else (file_access & LANDLOCK_FILE_ACCESS_MASK);
    if (access == 0) return;

    const rule = LandlockPathBeneathAttr{
        .allowed_access = access,
        .parent_fd = fd,
    };
    _ = std.os.linux.syscall4(
        .landlock_add_rule,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        LANDLOCK_RULE_PATH_BENEATH,
        @intFromPtr(&rule),
        0,
    );
}

fn applyLandlock(cfg: *const perm.Config) SandboxError!void {
    if (comptime builtin.os.tag != .linux) return error.SandboxUnsupportedOnOs;

    var handled: u64 = 0;
    if (cfg.read != .all) handled |= LANDLOCK_READ_DIR_ACCESS | LANDLOCK_ACCESS_FS_EXECUTE;
    if (cfg.write != .all) handled |= LANDLOCK_WRITE_DIR_ACCESS;
    if (handled == 0) return;

    const attr = LandlockRulesetAttr{ .handled_access_fs = handled & LANDLOCK_HANDLED_ALL_V1 };
    const rs_rc = std.os.linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(LandlockRulesetAttr), 0);
    if (std.os.linux.errno(rs_rc) != .SUCCESS) return error.LandlockFailed;
    const ruleset_fd: i32 = @intCast(rs_rc);
    defer _ = std.os.linux.close(ruleset_fd);

    switch (cfg.read) {
        .scoped => |scopes| {
            for (scopes) |s| {
                addLandlockPath(
                    ruleset_fd,
                    s.path,
                    LANDLOCK_READ_DIR_ACCESS & handled,
                    LANDLOCK_READ_FILE_ACCESS & handled,
                );
            }
        },
        .denied, .all => {},
    }

    switch (cfg.write) {
        .scoped => |scopes| {
            for (scopes) |s| {
                addLandlockPath(
                    ruleset_fd,
                    s.path,
                    LANDLOCK_WRITE_DIR_ACCESS & handled,
                    LANDLOCK_WRITE_FILE_ACCESS & handled,
                );
            }
        },
        .denied, .all => {},
    }

    // Outbound TLS/DNS resolution reads system certificates and resolver config.
    if (cfg.isAllowed(.net) and cfg.read != .all) {
        const net_sys_paths = [_][]const u8{
            "/etc/ssl",
            "/etc/ca-certificates",
            "/etc/resolv.conf",
            "/etc/hosts",
            "/etc/nsswitch.conf",
        };
        for (net_sys_paths) |p| {
            addLandlockPath(
                ruleset_fd,
                p,
                LANDLOCK_READ_DIR_ACCESS & handled,
                LANDLOCK_READ_FILE_ACCESS & handled,
            );
        }
    }

    const res_rc = std.os.linux.syscall2(.landlock_restrict_self, @as(usize, @bitCast(@as(isize, ruleset_fd))), 0);
    if (std.os.linux.errno(res_rc) != .SUCCESS) return error.LandlockFailed;
}

/// Locks down the current process using Linux PR_SET_NO_NEW_PRIVS, Landlock,
/// and a seccomp-bpf filter that keeps `io_uring_enter` enabled.
/// Fails closed on unsupported OSes or kernel errors.
pub fn apply(cfg: *const perm.Config) SandboxError!void {
    if (comptime builtin.os.tag != .linux) {
        return error.SandboxUnsupportedOnOs;
    } else {
        const nnp_rc = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        if (std.os.linux.errno(nnp_rc) != .SUCCESS) return error.NoNewPrivsFailed;

        try applyLandlock(cfg);

        var insns: [MAX_BPF_INSNS]SockFilter = undefined;
        const count = try buildSeccompProgram(builtin.cpu.arch, &insns);
        const prog = SockFprog{
            .len = @intCast(count),
            .filter = &insns,
        };
        const sec_rc = std.os.linux.prctl(
            @intFromEnum(std.os.linux.PR.SET_SECCOMP),
            std.os.linux.SECCOMP.MODE.FILTER,
            @intFromPtr(&prog),
            0,
            0,
        );
        if (std.os.linux.errno(sec_rc) != .SUCCESS) return error.SeccompFailed;
    }
}

pub fn applyIfRequested() void {
    if (!limits.get().sandbox) return;
    apply(perm.global()) catch |err| {
        cli.failWithHint(
            "sandbox initialization failed: {s}",
            .{@errorName(err)},
            "--simple-sandbox requires Linux 5.13+ with Landlock and seccomp",
            .{},
        );
    };
}

// ── Tests ──────────────────────────────────────────────────────────

fn evalSeccompBpf(program: []const SockFilter, arch: u32, nr: u32) u32 {
    var pc: usize = 0;
    var acc: u32 = 0;
    while (pc < program.len) {
        const insn = program[pc];
        switch (insn.code) {
            BPF_LD_W_ABS => {
                acc = switch (insn.k) {
                    SECCOMP_DATA_NR_OFFSET => nr,
                    SECCOMP_DATA_ARCH_OFFSET => arch,
                    else => 0,
                };
                pc += 1;
            },
            BPF_JMP_JEQ_K => {
                const jump: usize = if (acc == insn.k) insn.jt else insn.jf;
                pc += 1 + jump;
            },
            BPF_RET_K => return insn.k,
            else => unreachable,
        }
    }
    unreachable;
}

test "seccomp BPF filter blocks io_uring_setup/register and execve but allows io_uring_enter" {
    var arm_prog: [MAX_BPF_INSNS]SockFilter = undefined;
    const arm_len = try buildSeccompProgram(.aarch64, &arm_prog);
    const arm = arm_prog[0..arm_len];

    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(arm, AUDIT_ARCH_AARCH64, 425)); // io_uring_setup
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, evalSeccompBpf(arm, AUDIT_ARCH_AARCH64, 426)); // io_uring_enter
    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(arm, AUDIT_ARCH_AARCH64, 427)); // io_uring_register
    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(arm, AUDIT_ARCH_AARCH64, 221)); // execve
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, evalSeccompBpf(arm, AUDIT_ARCH_AARCH64, 63)); // read
    try std.testing.expectEqual(SECCOMP_RET_KILL_PROCESS, evalSeccompBpf(arm, AUDIT_ARCH_X86_64, 63)); // wrong arch

    var x64_prog: [MAX_BPF_INSNS]SockFilter = undefined;
    const x64_len = try buildSeccompProgram(.x86_64, &x64_prog);
    const x64 = x64_prog[0..x64_len];

    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(x64, AUDIT_ARCH_X86_64, 425)); // io_uring_setup
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, evalSeccompBpf(x64, AUDIT_ARCH_X86_64, 426)); // io_uring_enter
    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(x64, AUDIT_ARCH_X86_64, 427)); // io_uring_register
    try std.testing.expectEqual(SECCOMP_RET_ERRNO_EPERM, evalSeccompBpf(x64, AUDIT_ARCH_X86_64, 59)); // execve
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, evalSeccompBpf(x64, AUDIT_ARCH_X86_64, 0)); // read
    try std.testing.expectEqual(SECCOMP_RET_KILL_PROCESS, evalSeccompBpf(x64, AUDIT_ARCH_AARCH64, 0)); // wrong arch
}

test "sandbox apply fails closed on non-Linux hosts" {
    if (comptime builtin.os.tag != .linux) {
        const cfg = perm.Config{};
        try std.testing.expectError(error.SandboxUnsupportedOnOs, apply(&cfg));
    }
}
