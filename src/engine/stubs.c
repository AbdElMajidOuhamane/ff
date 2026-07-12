#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct Context Context;
typedef struct Value Value;

// Memory allocator expected by V8 binding
void* zigAlloc(const void* allocator, uint64_t bytes) {
    (void)allocator;
    return malloc(bytes);
}

// Inspector stubs
void v8_inspector__Channel__IMPL__sendResponse(
    void* self, void* data, int callId, const char* resp, size_t resp_len) {
    (void)self; (void)data; (void)callId; (void)resp; (void)resp_len;
}

void v8_inspector__Channel__IMPL__sendNotification(
    void* self, void* data, const char* notif, size_t notif_len) {
    (void)self; (void)data; (void)notif; (void)notif_len;
}

void v8_inspector__Channel__IMPL__flushProtocolNotifications(
    void* self, void* data) {
    (void)self; (void)data;
}

void v8_inspector__Client__IMPL__consoleAPIMessage(
    void* self, void* data, int contextGroupId, int errorLevel,
    const char* str1, size_t str1_len, const char* str2, size_t str2_len,
    void* stack) {
    (void)self; (void)data; (void)contextGroupId; (void)errorLevel;
    (void)str1; (void)str1_len; (void)str2; (void)str2_len; (void)stack;
}

const Context* v8_inspector__Client__IMPL__ensureDefaultContextInGroup(
    void* self, void* data, int contextGroupId) {
    (void)self; (void)data; (void)contextGroupId;
    return NULL;
}

int64_t v8_inspector__Client__IMPL__generateUniqueId(
    void* self, void* data) {
    (void)self; (void)data;
    return 0;
}

void v8_inspector__Client__IMPL__quitMessageLoopOnPause(
    void* self, void* data) {
    (void)self; (void)data;
}

void v8_inspector__Client__IMPL__runIfWaitingForDebugger(
    void* self, void* data, int contextGroupId) {
    (void)self; (void)data; (void)contextGroupId;
}

void v8_inspector__Client__IMPL__runMessageLoopOnPause(
    void* self, void* data, int contextGroupId) {
    (void)self; (void)data; (void)contextGroupId;
}

const char* v8_inspector__Client__IMPL__valueSubtype(
    void* self, void* data, const Context* ctx, const Value* val) {
    (void)self; (void)data; (void)ctx; (void)val;
    return NULL;
}

const char* v8_inspector__Client__IMPL__descriptionForValueSubtype(
    void* self, void* data, const Context* ctx, const Value* val) {
    (void)self; (void)data; (void)ctx; (void)val;
    return NULL;
}
