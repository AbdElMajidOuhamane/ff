let seq = 1;
export function newId() {
  return Date.now().toString(36) + "-" + (seq++).toString(36);
}

export function parseQuery(url) {
  const q = url.indexOf("?");
  if (q === -1) return {};
  const out = {};
  for (const pair of url.slice(q + 1).split("&")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    out[eq === -1 ? pair : pair.slice(0, eq)] = eq === -1 ? "" : pair.slice(eq + 1);
  }
  return out;
}

export function parsePath(url) {
  const q = url.indexOf("?");
  return q === -1 ? url : url.slice(0, q);
}
