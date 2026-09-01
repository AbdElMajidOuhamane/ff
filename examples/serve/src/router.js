const routes = [];
export function on(method, path, handler) { routes.push({ method, path, handler }); }

export function match(method, path) {
  for (const r of routes) {
    if (r.method === method && r.path === path) return r.handler;
  }
  return null;
}
