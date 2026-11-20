// HTTP benchmark workload for Deno — keep byte-identical with ff.js / bun.js.
const port = Number(Deno.env.get("PORT") ?? "8787");
const body = '{"message":"Hello, World!"}';
const headers = { "content-type": "application/json" };

Deno.serve({ port, hostname: "127.0.0.1" }, () => new Response(body, { headers }));