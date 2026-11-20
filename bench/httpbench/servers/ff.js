// HTTP benchmark workload for ff — keep byte-identical with deno.js / bun.js.
// Port comes from PORT (the harness sets it), host is loopback-only.
const port = Number(process.env.PORT ?? "8787");
const body = '{"message":"Hello, World!"}';
const headers = { "content-type": "application/json" };

http.serve({ port, hostname: "127.0.0.1" }, () => new Response(body, { headers }));