const sockets = [];

http.serve({
  port: 3000,
  websocket: {
    open(socket) {
      console.log("open", socket.id);
      sockets.push(socket);
    },
    message(socket, data) {
      if (data instanceof Uint8Array) {
        console.log("binary:", data.length, "bytes");
        socket.sendBinary(data); // echo binary back
      } else {
        console.log("message:", data);
        socket.send("echo: " + data);
      }
      for (const s of sockets) {
        if (s.id !== socket.id) s.send(data);
      }
      if (sockets.length >= 3) socket.close(1000, "done");
    },
    close(socket, code, reason) {
      console.log("close", socket.id, "code", code, "reason", reason);
      const i = sockets.indexOf(socket);
      if (i !== -1) sockets.splice(i, 1);
      if (sockets.length === 0) process.exit(0);
    },
  },
}, (url) => {
  if (url === "/ws") return { status: 101 };
  return { status: 404, body: "not found" };
});
