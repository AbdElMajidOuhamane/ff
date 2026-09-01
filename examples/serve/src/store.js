const todos = [];
let nextId = 1;

export function list() { return todos; }
export function add(text) {
  const todo = { id: String(nextId++), text, done: false };
  todos.push(todo);
  return todo;
}
export function done() { return todos.filter((t) => t.done); }
