const routes = [];
export function on(method, pattern, handler) {
  const keys = [];
  const parts = pattern.split("/").map((seg) => {
    if (seg.startsWith(":")) { keys.push(seg.slice(1)); return "([^/]+)"; }
    return seg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  });
  routes.push({ method, re: new RegExp("^" + parts.join("/") + "$"), keys, handler });
}

export function match(method, path) {
  let pathHit = false;
  for (const r of routes) {
    if (r.re.test(path)) {
      pathHit = true;
      if (r.method === method) {
        const m = path.match(r.re);
        const params = {};
        for (let i = 0; i < r.keys.length; i++) params[r.keys[i]] = m[i + 1];
        return { handler: r.handler, params };
      }
    }
  }
  return pathHit ? { mismatch: true } : null;
}
