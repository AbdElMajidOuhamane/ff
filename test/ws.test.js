import { check, done } from "./lib.mjs";

const received = [];
let binaryReceived = null;
const srv = http.serve({
  port: 0,
  websocket: {
    message(ws, msg) {
      if (typeof msg === "string") {
        received.push(msg);
      } else {
        binaryReceived = new Uint8Array(msg);
      }
    }
  }
}, () => new Response("ok"));

const ws = new WebSocket("ws://127.0.0.1:" + srv.port + "/");
ws.onopen = () => {
  ws.send("a");
  ws.send("b");
  ws.sendBinary(new Uint8Array([1, 2, 3]));
};

await new Promise((resolve) => {
  const deadline = Date.now() + 3000;
  const checkDone = () => {
    if (received.length >= 2 && binaryReceived !== null) {
      resolve();
    } else if (Date.now() > deadline) {
      resolve();
    } else {
      setTimeout(checkDone, 10);
    }
  };
  checkDone();
});

check("WebSocket back-to-back send preserves all messages", received.length === 2 && received[0] === "a" && received[1] === "b");
check("WebSocket client sendBinary", binaryReceived !== null && binaryReceived.length === 3 && binaryReceived[0] === 1 && binaryReceived[1] === 2 && binaryReceived[2] === 3);

ws.close();
await srv.close();

// Unclosed / failed WebSocket does not assert on runtime shutdown in ReleaseSafe/Debug
new WebSocket("ws://127.0.0.1:1/");

done("ws");
