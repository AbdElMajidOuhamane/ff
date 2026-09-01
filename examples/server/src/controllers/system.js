import { config } from "../config.js";
import { json } from "../http.js";
import { todoCount } from "../db.js";

export const root = () =>
  json({ name: config.name, version: config.version, endpoints: [
    "GET /health", "GET /api/todos", "POST /api/todos",
    "GET /api/todos/:id", "PUT /api/todos/:id", "PATCH /api/todos/:id", "DELETE /api/todos/:id",
  ] });

export const health = () =>
  json({ status: "ok", uptime: Date.now(), todoCount: todoCount(), pid: process.pid });
