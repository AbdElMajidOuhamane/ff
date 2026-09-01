// WSS echo round-trip against our own TLS server.
// Run (while server is up):  ff wss-client.js --ca cert.pem   (exit code 0 = pass)

const t0 = Date.now();
let fail = 0;
function ok(name, cond) {
  console.log((cond ? "OK   " : "FAIL ") + name);
  if (!cond) fail++;
}

let got_open = false, got_text = false, got_binary = false, got_close = false;

const ws = new WebSocket("wss://localhost:8443/ws");
ok("initial readyState is CONNECTING", ws.readyState === WebSocket.CONNECTING);

ws.onopen = () => {
  got_open = true;
  ok("wss handshake", true);
  ok("readyState is OPEN", ws.readyState === WebSocket.OPEN);
  ws.send("hello-tls");
};

ws.onmessage = (ev) => {
  console.log("recv: " + JSON.stringify(ev.data).slice(0, 100) + " len=" + ev.data.length); // [diag]
  if (typeof ev.data === "string") {
    got_text = true;
    ok("text echo over TLS", ev.data === "echo: hello-tls");
    ws.send(new Uint8Array([1, 2, 3, 4, 5]));
  } else if (ev.data instanceof Uint8Array) {
    got_binary = true;
    ok("binary echo over TLS", Array.from(ev.data).join(",") === "1,2,3,4,5");
    ws.close(1000, "done");
  }
};

ws.onclose = (ev) => {
  got_close = true;
  ok("clean close 1000", ev.code === 1000);
  ok("readyState is CLOSED", ws.readyState === WebSocket.CLOSED);
  ok("all wss events fired", got_open && got_text && got_binary && got_close);
  console.log("wss round-trip took " + (Date.now() - t0) + "ms");
  process.exit(fail === 0 ? 0 : 1);
};

ws.onerror = (ev) => {
  console.log("ws error: " + (ev && ev.message ? ev.message : "?"));
  ok("no error", false);
};
