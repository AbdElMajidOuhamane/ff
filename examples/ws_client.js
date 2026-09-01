let fail = 0;
function ok(name, cond) {
  console.log((cond ? "OK   " : "FAIL ") + name);
  if (!cond) fail++;
}

let got_open = false, got_text = false, got_binary = false, got_close = false;

http.serve({
  port: 3000,
  websocket: {
    open(s) {},
    message(s, data) {
      if (data instanceof Uint8Array) s.sendBinary(data);
      else s.send("echo: " + data);
    },
    close(s, code, reason) {},
  },
}, () => ({ status: 101 }));

const ws = new WebSocket("ws://127.0.0.1:3000/ws");
ok("WebSocket.CONNECTING === 0", WebSocket.CONNECTING === 0);
ok("initial readyState is CONNECTING", ws.readyState === WebSocket.CONNECTING);

ws.onopen = () => {
  got_open = true;
  ok("onopen fired", true);
  ok("readyState is OPEN", ws.readyState === WebSocket.OPEN);
  ws.send("ping");
};

ws.onmessage = (ev) => {
  if (typeof ev.data === "string") {
    got_text = true;
    ok("text echo", ev.data === "echo: ping");
    ws.send(new Uint8Array([1, 2, 3, 4, 5]));
  } else if (ev.data instanceof Uint8Array) {
    got_binary = true;
    ok("binary echo", Array.from(ev.data).join(",") === "1,2,3,4,5");
    ws.close(1000, "done");
  } else {
    ok("unknown message type", false);
  }
};

ws.onclose = (ev) => {
  got_close = true;
  ok("onclose fired", true);
  ok("close code 1000", ev.code === 1000);
  ok("readyState is CLOSED", ws.readyState === WebSocket.CLOSED);
  ok("all events fired", got_open && got_text && got_binary && got_close);
  process.exit(fail === 0 ? 0 : 1);
};

ws.onerror = () => { ok("no error", false); };
