// Fairyfly HTTP API demo server
// Contract: http.serve({ port }, (url, method, body) => ({ status, body }))

const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
const partsOf = (p) => p.split("/").filter((s) => s.length > 0);

function splitTarget(url) {
  const q = url.indexOf("?");
  return {
    path: q === -1 ? url : url.slice(0, q),
    query: q === -1 ? "" : url.slice(q + 1),
  };
}

// tiny pure-JS query parser
function parseQuery(qs) {
  const out = {};
  if (!qs) return out;
  for (const pair of qs.split("&")) {
    const eq = pair.indexOf("=");
    const k = eq === -1 ? pair : pair.slice(0, eq);
    const v = eq === -1 ? "" : decodeURIComponent(pair.slice(eq + 1));
    out[k] = v;
  }
  return out;
}

http.serve({ port: 3000 }, (url, method, body) => {
  const { path, query } = splitTarget(url);
  const parts = partsOf(path);
  const q = parseQuery(query);
  const bodyLen = body === undefined ? 0 : body.length;

  // --- index -------------------------------------------------------
  if (path === "/") {
    return {
      status: 200,
      body:
        "Fairyfly HTTP demo\n" +
        "  GET  /health                 json health\n" +
        "  GET  /echo                   echo url/method/query\n" +
        "  GET  /status/:code           any status\n" +
        "  GET  /json                   richer json\n" +
        "  GET  /api/todos              list\n" +
        "  POST /api/todos              create\n" +
        "  PUT  /api/todos/:id          update\n" +
        "  DELETE /api/todos/:id        delete\n" +
        "  POST /mirror                 see request body\n" +
        "  anything else                404\n",
    };
  }

  // --- health ------------------------------------------------------
  if (path === "/health") {
    return json({ ok: true, uptime: Date.now(), todos: todos.length });
  }

  // --- echo --------------------------------------------------------
  if (path === "/echo") {
    return json({ url, method, path, query, q, bodyLen });
  }

  // --- status passthrough ------------------------------------------
  if (parts.length === 2 && parts[0] === "status") {
    const code = Number(parts[1]);
    if (code >= 100 && code <= 599) {
      return { status: code, body: `${code}: via /status/${code}` };
    }
    return json({ error: "invalid status" }, 400);
  }

  // --- json --------------------------------------------------------
  if (path === "/json") {
    return json({
      name: "fairyfly-demo",
      routes: ["/health", "/echo", "/status/:id", "/api/todos"],
      nested: { enabled: true, stamp: Date.now() },
    });
  }

  // --- todos CRUD --------------------------------------------------
  if (path === "/api/todos" && method === "GET") {
    return json({ todos, count: todos.length });
  }
  if (path === "/api/todos" && method === "POST") {
    if (bodyLen === 0) return json({ error: "empty body" }, 422);
    try {
      const item = JSON.parse(body);
      item.id = String(todos.length + 1);
      todos.push(item);
      return json({ todo: item }, 201);
    } catch {
      return json({ error: "invalid json body" }, 400);
    }
  }
  if (parts.length === 3 && parts[0] === "api" && parts[1] === "todos") {
    const id = parts[2];
    const t = todos.find((x) => x.id === id);
    if (!t) return json({ error: "not found" }, 404);
    if (method === "GET") return json({ todo: t });
    if (method === "DELETE") {
      const i = todos.indexOf(t);
      todos.splice(i, 1);
      return json({ ok: true });
    }
    if (method === "PUT") {
      try { Object.assign(t, JSON.parse(body)); } catch {}
      return json({ todo: t });
    }
  }

  // --- mirror (bodies are passed through as strings) ---------------
  if (path === "/mirror") {
    return json({
      hmm: `got ${method} with ${bodyLen} body bytes`,
      preview: (body || "").slice(0, 200),
    });
  }

  // --- fallback -----------------------------------------------------
  return json({ error: "not found" }, 404);
});

const todos = [
  { id: "1", text: "Learn Fairyfly", done: true },
  { id: "2", text: "Bench the runtime", done: false },
];
