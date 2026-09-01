// HTTPS + WSS smoke-test server — TLS configured from JS (Node-style).
// Run:  ff start            (no --cert/--key needed!)
// Covers: GET /health, POST /echo, GET /big (20KB, multi-record), WSS echo on /ws

const hits = { http: 0 };
let ws_open = 0;

http.serve({
  port: 8443,
  // cert/key accept file paths OR inline PEM content ("-----BEGIN ...").
  tls: { cert: "cert.pem", key: "key.pem" },
  websocket: {
    open(s) {
      ws_open++;
      console.log("[wss] client connected (open=" + ws_open + ")");
    },
    message(s, data) {
      if (data instanceof Uint8Array) {
        s.sendBinary(data);
      } else {
        s.send("echo: " + data);
      }
    },
    close(s) {
      ws_open--;
      console.log("[wss] client closed (open=" + ws_open + ")");
    },
  },
}, (url, method, body) => {
  const q = url.indexOf("?");
  const path = q === -1 ? url : url.slice(0, q);

  if (path === "/ws") return { status: 101 };

  hits.http++;
  if (path === "/health") {
    return { status: 200, body: JSON.stringify({ ok: true, tls: true, http_hits: hits.http, ws_open, ts: Date.now() }) };
  }
  if (path === "/echo" && method === "POST") return { status: 200, body: body };
  if (path === "/echo" && method === "GET") return { status: 200, body: "echo-get-ok" };
  if (path === "/big") {
    let s = "";
    for (let i = 0; i < 1000; i++) s += "0123456789abcdefghij"; // 20000 bytes
    return { status: 200, body: s };
  }
  return { status: 404, body: JSON.stringify({ error: "not found", path }) };
});

console.log("[server] https/wss test server ready on :8443 (TLS from JS)");
