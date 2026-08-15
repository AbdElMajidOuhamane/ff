// In-memory store
const todos = [
  { id: "1", text: "Learn Fairyfly", done: true },
  { id: "2", text: "Build a server", done: false },
];

const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
const partsOf = (p) => p.split("/").filter((s) => s.length > 0);

// Handler signature the runtime actually uses: (url, method), both strings.
// url is the raw request-target, e.g. "/api/todos?search=x".
http.serve({ port: 3000 }, (url, method) => {
  const q = url.indexOf("?");
  const path = q === -1 ? url : url.slice(0, q);
  const query = q === -1 ? "" : url.slice(q + 1);
  const parts = partsOf(path);

  // --- status-code demos: /status/:code ------------------------------
  if (parts[0] === "status" && parts.length === 2) {
    const code = Number(parts[1]);
    if (code >= 100 && code <= 599) return { status: code, body: `status ${code}` };
    return json({ error: "invalid status code" }, 400);
  }

  // --- GET / ----------------------------------------------------------
  if (path === "/") {
    return { status: 200, body:
      "Fairyfly test server\n" +
      "  GET  /                       index\n" +
      "  GET  /health                 health check\n" +
      "  GET  /echo                   echoes url/path/query/method\n" +
      "  GET  /status/:code           returns that HTTP status\n" +
      "  GET  /api/todos              list todos (?search= filters)\n" +
      "  GET  /api/todos/:id          get one\n" +
      "  POST /api/todos              create (501: body not parsed yet)\n" +
      "  PUT  /api/todos/:id          update (501: body not parsed yet)\n" +
      "  DELETE /api/todos/:id        delete\n" +
      "  anything else               404\n" };
  }

  // --- GET /health -----------------------------------------------------
  if (path === "/health") return json({ status: "ok", uptime: Date.now(), todos: todos.length });

  // --- GET /echo -------------------------------------------------------
  if (path === "/echo") return json({ url, path, query, method, todos: todos.length });

  // --- GET /api/todos ---------------------------------------------------
  if (path === "/api/todos" && method === "GET") {
    let result = todos;
    if (query.startsWith("search=")) {
      const qs = query.slice("search=".length).toLowerCase();
      result = todos.filter((t) => t.text.toLowerCase().includes(qs));
    }
    return json({ todos: result, count: result.length });
  }

  // --- POST /api/todos --------------------------------------------------
  if (path === "/api/todos" && method === "POST") {
    return json({ error: "request body parsing not supported yet" }, 501);
  }

  // --- /api/todos/:id ---------------------------------------------------
  if (parts.length === 3 && parts[0] === "api" && parts[1] === "todos") {
    const id = parts[2];
    const idx = todos.findIndex((t) => t.id === id);

    if (method === "GET") {
      if (idx === -1) return json({ error: `Todo '${id}' not found` }, 404);
      return json(todos[idx]);
    }
    if (method === "DELETE") {
      if (idx === -1) return json({ error: `Todo '${id}' not found` }, 404);
      todos.splice(idx, 1);
      return json({ deleted: true, id });
    }
    if (method === "PUT") {
      return json({ error: "request body parsing not supported yet" }, 501);
    }
  }

  // --- fallbacks ---------------------------------------------------------
  if (method !== "GET") return json({ error: "method not allowed" }, 405);
  return json({ error: "Not found" }, 404);
});
