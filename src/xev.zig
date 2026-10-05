const builtin = @import("builtin");
const inner = @import("xev-inner");
const ffcfg = @import("ffcfg");

// -Dio_uring (default false): opt-in io_uring backend on Linux. Default is
// epoll — universally available, while io_uring needs Linux 5.1+ and is
// blocked by some seccomp/container policies (e.g. Docker Desktop).
const use_io_uring = builtin.os.tag == .linux and ffcfg.io_uring;

const chosen = if (use_io_uring) inner.IO_Uring else if (builtin.os.tag == .linux) inner.Epoll else inner;

pub const Loop = chosen.Loop;
pub const Timer = chosen.Timer;
pub const Completion = chosen.Completion;
pub const TCP = chosen.TCP;
pub const CallbackAction = chosen.CallbackAction;
pub const AcceptError = chosen.AcceptError;
pub const CloseError = chosen.CloseError;
pub const ReadBuffer = chosen.ReadBuffer;
pub const WriteBuffer = chosen.WriteBuffer;
pub const ReadError = chosen.ReadError;
pub const WriteError = chosen.WriteError;
pub const ConnectError = chosen.ConnectError;
pub const ThreadPool = inner.ThreadPool;
pub const Async = chosen.Async;
pub const available = inner.available;
pub const backend = chosen.backend;
pub const is_io_uring = use_io_uring;
