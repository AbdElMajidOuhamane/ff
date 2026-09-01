import { config } from "./src/config.js";
import { on, match } from "./src/router.js";
import { todosApi } from "./src/controllers/todos.js";
import { root, health } from "./src/controllers/system.js";
import { notFound, notAllowed, crash, parseQuery } from "./src/http.js";
import { withLogger } from "./src/middleware.js";

on("GET", "/", root);
on("GET", "/health", health);
on("GET", "/api/todos", todosApi.list);
on("POST", "/api/todos", todosApi.create);
on("GET", "/api/todos/:id", todosApi.get);
on("PUT", "/api/todos/:id", todosApi.update);
on("PATCH", "/api/todos/:id", todosApi.update);
on("DELETE", "/api/todos/:id", todosApi.remove);

async function dispatch(req) {
  const q = req.url.indexOf("?");
  const path = q === -1 ? req.url : req.url.slice(0, q);
  const query = parseQuery(req.url);

  const hit = match(req.method, path);
  if (!hit) return notFound();
  if (hit.mismatch) return notAllowed();

  try {
    return await hit.handler(req, hit.params, query);
  } catch (e) {
    return crash(e);
  }
}

http.serve({ port: config.port }, withLogger(dispatch));
