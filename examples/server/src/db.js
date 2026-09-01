import { newId } from "./util.js";

const todos = new Map();
let nextId = 1;

function seed() {
  const mk = (text, done) => {
    const id = String(nextId++);
    todos.set(id, { id, text, done });
  };
  mk("Learn Fairyfly", true);
  mk("Build a REST API", false);
}
seed();

export function listTodos(search, done) {
  let rows = [...todos.values()];
  if (search !== undefined) {
    const s = search.toLowerCase();
    rows = rows.filter((t) => t.text.toLowerCase().includes(s));
  }
  if (done !== undefined) rows = rows.filter((t) => t.done === (done === "true"));
  rows.sort((a, b) => (a.id < b.id ? -1 : 1));
  return { rows, count: rows.length };
}

export function getTodo(id) {
  return todos.get(id) ?? null;
}

export function createTodo(text, done) {
  const todo = { id: newId(), text, done: done === true };
  todos.set(todo.id, todo);
  return todo;
}

export function updateTodo(id, patch) {
  const todo = todos.get(id);
  if (!todo) return null;
  if (typeof patch.text === "string") todo.text = patch.text.trim();
  if (typeof patch.done === "boolean") todo.done = patch.done;
  return todo;
}

export function deleteTodo(id) {
  return todos.delete(id);
}

export function todoCount() {
  return todos.size;
}
