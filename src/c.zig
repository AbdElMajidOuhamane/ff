
pub const c = @cImport({
    @cInclude("binding.h");
    @cInclude("unistd.h");
    @cInclude("libc.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("pthread.h");
    @cInclude("semaphore.h");
    @cInclude("sys/resource.h");
});
