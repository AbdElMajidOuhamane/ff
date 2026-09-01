// examples/api-server.js — REST API server
// handler signature: (url, method, body) => { status, body }
// returns   { status:Number, body:String } (body is sent verbatim)

const todos = [
  { id: "1", text: "Learn Fairyfly", done: false },
  { id: "2", text: "Ship an API", done: false },
];

const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
const partsOf = (p) => p.split("/").filter((s) => s.length > 0);
const nextId = () => String(Math.max(0, ...todos.map((t) => Number(t.id))) + 1);

http.serve({ port: 3000 }, (url, method, body) => {
  const q = url.indexOf("?");
  const path = q === -1 ? url : url.slice(0, q);
  const parts = partsOf(path);

  // --- GET / -------------------------------------------------------
  if (path === "/") {
    return json({
      endpoints: {
        "GET    /todos": "list",
        "GET    /todos/:id": "get one",
        "POST   /todos": "create  (body: { text })",
        "PUT    /todos/:id": "update  (body: { text, done })",
        "DELETE /todos/:id": "remove",
      },
    });
  }

  // --- /todos ------------------------------------------------------
  if (parts[0] === "todos") {
    // list
    if (parts.length === 1 && method === "GET") {
      return json({ count: todos.length, todos });
    }
    // get one
    if (parts.length === 2 && method === "GET") {
      const t = todos.find((x) => x.id === parts[1]);
      return t ? json(t) : json({ error: "not found" }, 404);
    }
    // create
    if (parts.length === 1 && method === "POST") {
      let data;
      try { data = JSON.parse(body); } catch (_) { return json({ error: "invalid JSON" }, 400); }
      if (typeof data.text !== "string") return json({ error: "field 'text' (string) required" }, 400);
      const t = { id: nextId(), text: data.text, done: Boolean(data.done) };
      todos.push(t);
      return json(t, 201);
    }
    // update
    if (parts.length === 2 && method === "PUT") {
      const i = todos.findIndex((x) => x.id === parts[1]);
      if (i === -1) return json({ error: "not found" }, 404);
      let data;
      try { data = JSON.parse(body); } catch (_) { return json({ error: "invalid JSON" }, 400); }
      if (data.text !== undefined) todos[i].text = data.text;
      if (data.done !== undefined) todos[i].done = Boolean(data.done);
      return json(todos[i]);
    }
    // delete
    if (parts.length === 2 && method === "DELETE") {
      const i = todos.findIndex((x) => x.id === parts[1]);
      if (i === -1) return json({ error: "not found" }, 404);
      const [removed] = todos.splice(i, 1);
      return json({ deleted: true, id: removed.id });
    }
    return json({ error: "method not allowed" }, 405);
  }

  // --- health + 404 ------------------------------------------------
  if (path === "/health") return json({ status: "ok", uptime: Date.now() });
  return json({ error: "not found" }, 404);
});
