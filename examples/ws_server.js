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
