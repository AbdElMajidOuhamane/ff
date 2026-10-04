import { check, done } from "./lib.mjs";

// Flagship smoke: http.serve → fetch round-trip. Tries candidate ports so
// a busy port fails over instead of flaking (serve throws on bind failure).
const PORTS = [39871, 39872, 39873];
let base = null;
for (const port of PORTS) {
  try {
    http.serve({ port }, (url, method) => {
      const path = url.split("?")[0];
      if (path === "/health") return { status: 200, body: "ok" };
      if (path === "/echo" && method === "POST") return { status: 201, body: "created" };
      return { status: 404, body: "not found" };
    });
    base = "http://127.0.0.1:" + port;
    break;
  } catch (e) {}
}
if (base === null) throw new Error("http test: could not bind any candidate port");

const r = await fetch(base + "/health");
check("status 200", r.status === 200);
check("body ok", (await r.text()) === "ok");

const n = await fetch(base + "/nope");
check("404 route", n.status === 404);
check("404 body", (await n.text()) === "not found");

done("http");
