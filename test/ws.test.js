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

// Helper: poll condition until met or timeout (ms)
async function waitUntil(pred, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (!pred() && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 10));
  }
}

// Regression 1 (TX lost wakeup): single send inside onopen with 10ms spin before return
{
  const txGot = [];
  const txSrv = http.serve({
    port: 0,
    websocket: {
      message(sock, msg) {
        txGot.push(msg);
      }
    }
  }, () => new Response("ok"));
  const txWs = new WebSocket("ws://127.0.0.1:" + txSrv.port + "/");
  txWs.onopen = () => {
    txWs.send("only-in-onopen");
    const end = performance.now() + 10;
    while (performance.now() < end) {}
  };
  await waitUntil(() => txGot.length >= 1, 2000);
  check("WebSocket single send in onopen is not lost when handler delays return", txGot.length === 1 && txGot[0] === "only-in-onopen");
  txWs.close();
  await txSrv.close();
}

// Regression 2 (RX lost wakeup + buffered rd_buf resumption): receive-only client with slow onopen/onmessage
{
  const rxGot = [];
  const rxSrv = http.serve({
    port: 0,
    websocket: {
      open(sock) {
        sock.send("push-1");
        sock.send("push-2");
      }
    }
  }, () => new Response("ok"));
  const rxWs = new WebSocket("ws://127.0.0.1:" + rxSrv.port + "/");
  rxWs.onopen = () => {
    const end = performance.now() + 10;
    while (performance.now() < end) {}
  };
  rxWs.onmessage = (e) => {
    rxGot.push(e.data);
    const end = performance.now() + 5;
    while (performance.now() < end) {}
  };
  await waitUntil(() => rxGot.length >= 2, 2000);
  check("WebSocket receive-only client receives back-to-back server pushes after slow onopen/onmessage", rxGot.length === 2 && rxGot[0] === "push-1" && rxGot[1] === "push-2");
  rxWs.close();
  await rxSrv.close();
}

// Regression 3 (reply inside onmessage): echo client sends reply then delays return
{
  const echoGot = [];
  const echoSrv = http.serve({
    port: 0,
    websocket: {
      open(sock) {
        sock.send("ping-1");
      },
      message(sock, msg) {
        echoGot.push(msg);
      }
    }
  }, () => new Response("ok"));
  const echoWs = new WebSocket("ws://127.0.0.1:" + echoSrv.port + "/");
  echoWs.onmessage = (e) => {
    echoWs.send("pong:" + e.data);
    const end = performance.now() + 10;
    while (performance.now() < end) {}
  };
  await waitUntil(() => echoGot.length >= 1, 2000);
  check("WebSocket reply sent inside onmessage is not lost when handler delays return", echoGot.length === 1 && echoGot[0] === "pong:ping-1");
  echoWs.close();
  await echoSrv.close();
}

// Regression 4 (> 4096 B single frames streamed across read buffers up to WS_MSG_SIZE)
{
  const bigBin = new Uint8Array(4096);
  for (let i = 0; i < bigBin.length; i++) bigBin[i] = (i * 7 + 3) & 255;
  const bigText = "B".repeat(16000);
  let gotBin = null;
  let gotText = null;
  const bigSrv = http.serve({
    port: 0,
    websocket: {
      message(sock, msg) {
        if (typeof msg === "string") {
          sock.send(msg);
        } else {
          sock.sendBinary(msg);
        }
      },
    },
  }, () => new Response("ok"));
  const bigWs = new WebSocket("ws://127.0.0.1:" + bigSrv.port + "/");
  bigWs.binaryType = "arraybuffer";
  bigWs.onopen = () => {
    bigWs.sendBinary(bigBin);
    bigWs.send(bigText);
  };
  bigWs.onmessage = (e) => {
    if (typeof e.data === "string") {
      gotText = e.data;
    } else {
      gotBin = new Uint8Array(e.data);
    }
  };
  await waitUntil(() => gotBin !== null && gotText !== null, 3000);
  const binOk = gotBin !== null && gotBin.length === bigBin.length && gotBin.every((b, i) => b === bigBin[i]);
  check("WebSocket 4096 B binary frame echoes intact", binOk);
  check("WebSocket 16000 B text frame echoes intact", gotText === bigText);
  bigWs.close();
  await bigSrv.close();
}

// Unclosed / failed WebSocket does not assert on runtime shutdown in ReleaseSafe/Debug
new WebSocket("ws://127.0.0.1:1/");

done("ws");
