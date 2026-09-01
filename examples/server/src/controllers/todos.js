import { listTodos, getTodo, createTodo, updateTodo, deleteTodo } from "../db.js";
import { json, badRequest, notFound } from "../http.js";
import { readJson } from "../http.js";

export const todosApi = {
  async list(req, params, query) {
    const { rows, count } = listTodos(query.search, query.done);
    return json({ data: rows, count });
  },

  async get(req, params) {
    const todo = getTodo(params.id);
    return todo ? json({ data: todo }) : notFound();
  },

  async create(req) {
    let body;
    try {
      body = await readJson(req);
    } catch {
      return badRequest("Invalid JSON body");
    }
    if (typeof body !== "object" || typeof body.text !== "string" || !body.text.trim()) {
      return badRequest("Field 'text' (non-empty string) is required");
    }
    const todo = createTodo(body.text.trim(), body.done);
    return json({ data: todo }, 201);
  },

  async update(req, params) {
    let body;
    try {
      body = await readJson(req);
    } catch {
      return badRequest("Invalid JSON body");
    }
    if (typeof body !== "object") return badRequest("JSON object body required");
    const todo = updateTodo(params.id, body);
    return todo ? json({ data: todo }) : notFound();
  },

  async remove(req, params) {
    return deleteTodo(params.id) ? { status: 204, body: "" } : notFound();
  },
};
