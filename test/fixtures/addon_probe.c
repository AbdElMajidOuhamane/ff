// Test fixture for test/ffi.test.js §8 — struct-by-value parameters.
// Contract (kept in sync with ffi.test.js §8):
//   typedef struct { const uint8_t *ptr; int32_t len; } probe_blob;
//   probe_blob probe_add_blob(probe_blob b) { b.len *= 2; return b; }
// Layout on LP64: ptr @0 (8 bytes), len @8 (4 bytes), sizeof = 16 —
// must match ffi.struct([["ptr","pointer"],["len","i32"]]).

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *ptr;
    int32_t len;
} probe_blob;

// Pass-through pointer, doubled length — exercises struct-by-value in
// both directions (parameter and result) in a single call.
probe_blob probe_add_blob(probe_blob b) {
    b.len *= 2;
    return b;
}

// Struct result without a parameter: points at static data.
static const uint8_t probe_data[] = "addon-probe"; // 11 bytes

probe_blob probe_make_blob(void) {
    probe_blob b = { probe_data, (int32_t)(sizeof(probe_data) - 1) };
    return b;
}

// Layout oracles: let tests cross-check ffi.struct's hand-computed
// size/offsets against the C compiler's own answers.
uint32_t probe_sizeof_blob(void) { return (uint32_t)sizeof(probe_blob); }
uint32_t probe_offsetof_len(void) { return (uint32_t)offsetof(probe_blob, len); }
// Nested-struct round trip for ffi.test.js §9. Layout on LP64:
// id @0 (4B), inner @4 (8B: x @4, y @8), sizeof = 12.
typedef struct {
    int32_t x, y;
} probe_inner;

typedef struct {
    int32_t id;
    probe_inner inner;
} probe_outer;

// Echo with observable mutation: id+1, x+10, y+100.
probe_outer probe_nested(probe_outer o) {
    o.id += 1;
    o.inner.x += 10;
    o.inner.y += 100;
    return o;
}


// Callback probes for the P2b.1 verification script.
typedef int32_t (*probe_cb2)(int32_t, int32_t);
int32_t probe_apply(probe_cb2 f, int32_t a, int32_t b) {
    return f ? f(a, b) : -1;
}

// ── P2b.2/P2b.3 probes: nonblocking + cross-thread callbacks ──
#include <pthread.h>
#include <time.h>

void probe_sleep_ms(int32_t ms) {
    struct timespec ts = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

// Writes buf[i] = i through a copied buffer; copy-back happens at settle.
int32_t probe_fill(uint8_t *buf, int32_t n) {
    for (int32_t i = 0; i < n; i++) buf[i] = (uint8_t)i;
    return n;
}

typedef struct {
    probe_cb2 f;
    int32_t a, b, r;
} probe_thr_args;

static void *probe_thr_main(void *p) {
    probe_thr_args *t = (probe_thr_args *)p;
    t->r = t->f(t->a, t->b);
    return NULL;
}

// Invokes f on a thread C owns — the callback must not run on that thread.
int32_t probe_apply_on_thread(probe_cb2 f, int32_t a, int32_t b) {
    pthread_t th;
    probe_thr_args t = { f, a, b, -100 };
    if (!f) return -1;
    if (pthread_create(&th, NULL, probe_thr_main, &t) != 0) return -2;
    pthread_join(th, NULL);
    return t.r;
}
// ── Phase 2c probes: unions ──
typedef union {
    int32_t i;
    float f;
    uint8_t bytes[4];
} probe_u4;

probe_u4 probe_union_identity(probe_u4 u) {
    u.i += 1;
    return u;
}

// Nested union-in-struct. Layout on LP64: tag @0 (4B), val @4 (4B),
// sizeof = 8 — must match ffi.struct([["tag","i32"],["val",{union:[…]}]]).
typedef struct {
    int32_t tag;
    probe_u4 val;
} probe_tagged;

probe_tagged probe_tagged_bump(probe_tagged t) {
    t.tag += 1;
    t.val.i += 10;
    return t;
}

typedef int32_t (*probe_cb_u)(probe_u4);
int32_t probe_call_union_i(probe_cb_u f, int32_t x) {
    probe_u4 u;
    u.i = x;
    return f ? f(u) : -1;
}
