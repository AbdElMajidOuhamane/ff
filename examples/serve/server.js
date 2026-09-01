import { json, jsonError } from "./src/http.js";
import { on, match } from "./src/router.js";
import * as store from "./src/store.js";

// Register the routes up front.
on("GET", "/", (q) => json(store.list()));
on("GET", "/add", (q) => {
  const text = decodeURIComponent(q.split("text=")[1] || "untitled");
  return json(store.add(text));
});
on("GET", "/done", () => json(store.done()));

// The handler runs per request: (url, method, body) -> { status, body }.
http.serve({ port: 3000 }, (url, method, body) => {
  const q = url.indexOf("?");
  const path = q === -1 ? url : url.slice(0, q);
  const query = q === -1 ? "" : url.slice(q + 1);

  const hit = match(method, path);
  return hit ? hit(query) : jsonError("Not Found", 404);
});
