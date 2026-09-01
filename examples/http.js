const todos = [];

const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });

http.serve({ port: 3000 }, (url, method) => {
  const path = url.split("?")[0];
  if (path === "/health") return json({ ok: true });

  if (path === "/todos" && method === "GET") return json({ todos });
  if (path === "/todos" && method === "POST") {
    return json({ error: "body parsing not supported yet" }, 501);
  }
  return json({ error: "not found" }, 404);
});
