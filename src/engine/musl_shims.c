// glibc ABI shims for statically linking the glibc-built libc_v8 (V8/ICU/libc++)
// archive into musl. All weak: a musl-provided strong symbol takes precedence.
#define _GNU_SOURCE  // exposes pthread_getattr_np (musl pthread.h:222)
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wchar.h>

__attribute__((weak)) FILE *fopen64(const char *path, const char *mode) { return fopen(path, mode); }
__attribute__((weak)) FILE *tmpfile64(void) { return tmpfile(); }
__attribute__((weak)) int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open(path, flags, mode);
}
__attribute__((weak)) int fstat64(int fd, struct stat *st) { return fstat(fd, st); }
__attribute__((weak)) int stat64(const char *path, struct stat *st) { return stat(path, st); }
__attribute__((weak)) struct dirent *readdir64(DIR *dirp) { return readdir(dirp); }
__attribute__((weak)) int ftruncate64(int fd, off_t length) { return ftruncate(fd, length); }
__attribute__((weak)) int fseeko64(FILE *stream, off_t off, int whence) { return fseeko(stream, off, whence); }
__attribute__((weak)) off_t ftello64(FILE *stream) { return ftello(stream); }
__attribute__((weak)) ssize_t pread64(int fd, void *buf, size_t count, off_t offset) { return pread(fd, buf, count, offset); }
__attribute__((weak)) void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off) { return mmap(addr, len, prot, flags, fd, off); }

__attribute__((weak)) int __vsnprintf_chk(char *s, size_t maxlen, int flag, size_t slen, const char *fmt, va_list ap) { return vsnprintf(s, maxlen, fmt, ap); }
__attribute__((weak)) int __vfprintf_chk(FILE *stream, int flag, const char *fmt, va_list ap) { return vfprintf(stream, fmt, ap); }

__attribute__((weak)) long __sysconf(int name) { return sysconf(name); }
__attribute__((weak)) size_t __mbrlen(const char *s, size_t n, mbstate_t *ps) { return mbrlen(s, n, ps); }

__attribute__((weak)) void *__libc_stack_end;

__attribute__((constructor)) static void libc_stack_end_init(void) {
    pthread_attr_t attr;
    if (pthread_getattr_np(pthread_self(), &attr) == 0) {
        void *base;
        size_t size;
        if (pthread_attr_getstack(&attr, &base, &size) == 0 && base != NULL && size > 0) {
            __libc_stack_end = (char *)base + size;
        }
        pthread_attr_destroy(&attr);
    }
}

__attribute__((weak)) int backtrace(void **buffer, int size) { (void)buffer; (void)size; return 0; }
__attribute__((weak)) char **backtrace_symbols(void *const *buffer, int size) { (void)buffer; (void)size; return 0; }
__attribute__((weak)) void backtrace_symbols_fd(void *const *buffer, int size, int fd) { (void)buffer; (void)size; (void)fd; }
