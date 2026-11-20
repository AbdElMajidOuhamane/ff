// HTTP benchmark workload for Bun — keep byte-identical with ff.js / deno.js.
const port = Number(process.env.PORT ?? "8787");
const body = '{"message":"Hello, World!"}';
const headers = { "content-type": "application/json" };

Bun.serve({
  port,
  hostname: "127.0.0.1",
  fetch: () => new Response(body, { headers }),
});