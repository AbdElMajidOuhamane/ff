// Tiny test assertion library — dogfoods the ESM module loader.
let passed = 0;
let failed = 0;

export function check(name, cond) {
    if (cond) {
        passed += 1;
    } else {
        failed += 1;
        console.log(`FAIL: ${name}`);
    }
}

// Always exits: 0 = all green, 1 = any failure.
// process.exit also stops the event loop, so server-fixture tests
// (which keep a listener alive) terminate cleanly.
export function done(name) {
    console.log(`[${name}] pass:${passed} fail:${failed}`);
    process.exit(failed > 0 ? 1 : 0);
}
