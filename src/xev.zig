const builtin = @import("builtin");
const inner = @import("xev-inner");

const chosen = if (builtin.os.tag == .linux) inner.Epoll else inner;

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
