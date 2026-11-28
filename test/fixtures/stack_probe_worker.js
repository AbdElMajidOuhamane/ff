function recurse(n) {
  return recurse(n + 1);
}

try {
  recurse(0);
  postMessage({ ok: false, error: "did not throw" });
} catch (e) {
  postMessage({ ok: true, name: e.constructor ? e.constructor.name : "Error", message: e.message });
}
