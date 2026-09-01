// In-memory store
const todos = [
  { id: "1", text: "Learn Fairyfly", done: true },
  { id: "2", text: "Build a server", done: false },
];
let nextId = 3;

const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
const partsOf = (p) => p.split("/").filter((s) => s.length > 0);

// Handler signature the runtime uses: (url, method, body).
// url is the raw request-target, e.g. "/api/todos?search=x".
// method is uppercase. body is the raw request payload ("" for GET).
http.serve({ port: 3000 }, (url, method, body) => {
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
      "  GET  /echo                   echoes url/path/query/method/body\n" +
      "  GET  /status/:code           returns that HTTP status\n" +
      "  GET  /api/todos              list todos (?search= filters)\n" +
      "  GET  /api/todos/:id          get one\n" +
      "  POST /api/todos              create\n" +
      "  PUT  /api/todos/:id          update\n" +
      "  DELETE /api/todos/:id        delete\n" +
      "  anything else               404\n" };
  }

  // --- GET /health -----------------------------------------------------
  if (path === "/health") return json({ status: "ok", uptime: Date.now(), todos: todos.length });

  // --- GET /echo -------------------------------------------------------
  if (path === "/echo") return json({ url, path, query, method, body, todos: todos.length });

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
    let data;
    try { data = JSON.parse(body); }
    catch { return json({ error: "invalid JSON body" }, 400); }
    const todo = { id: String(nextId++), text: String(data.text ?? ""), done: Boolean(data.done) };
    todos.push(todo);
    return json(todo, 201);
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
      if (idx === -1) return json({ error: `Todo '${id}' not found` }, 404);
      let data;
      try { data = JSON.parse(body); }
      catch { return json({ error: "invalid JSON body" }, 400); }
      if (data.text !== undefined) todos[idx].text = String(data.text);
      if (data.done !== undefined) todos[idx].done = Boolean(data.done);
      return json(todos[idx]);
    }
  }

  // --- fallbacks ---------------------------------------------------------
  if (method !== "GET") return json({ error: "method not allowed" }, 405);
  return json({ error: "Not found" }, 404);
});
