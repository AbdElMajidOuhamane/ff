const sockets = [];

http.serve({
  port: 3000,
  websocket: {
    open(socket) {
      console.log("open", socket.id);
      sockets.push(socket);
    },
    message(socket, data) {
      console.log("message:", data);
      socket.send("echo: " + data);
      for (const s of sockets) {
        if (s.id !== socket.id) s.send(data);
      }
    },
    close(socket) {
      console.log("close", socket.id);
      const i = sockets.indexOf(socket);
      if (i !== -1) sockets.splice(i, 1);
    },
  },
}, (url) => {
  if (url === "/ws") return { status: 101 };
  return { status: 404, body: "not found" };
});
