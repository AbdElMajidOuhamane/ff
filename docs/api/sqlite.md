---
title: SQLite API
description: Database reference — open, query, write, transactions, and introspection.
order: 3
---

# SQLite API

`Database` is global — no import, no package. One file per database, synchronous calls, WAL mode on, 5s busy timeout by default.

## Quick look

```js
// notes.js
const db = Database.open("notes.db");
db.execNoArgs(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL
)`);

db.exec("INSERT INTO notes (text) VALUES (?)", ["buy milk"]);
console.log(db.rows("SELECT id, text FROM notes"));
// [ { id: 1, text: "buy milk" } ]

db.close();
```

```sh
ff notes.js
```

## `Database.open(path)`

```js
const db = Database.open("app.db");
const mem = Database.open(":memory:");
```

Opens (creating when missing) and returns the handle. Every open enables `PRAGMA journal_mode=WAL` and a 5000ms busy timeout — override the latter per handle with `busyTimeout(ms)`.

> **Caution:** The path is relative to the process cwd. `Database.open("app.db")` in `ff start` lands next to where you launched, not necessarily next to your script.

## Reading: `row` / `rows`

```js
const one = db.row("SELECT id, text FROM notes WHERE id = ?", [1]);
console.log(one); // { id: 1, text: "buy milk" } — or null when no row matches

const all = db.rows("SELECT id, text FROM notes ORDER BY id");
console.log(all.length); // 0 when empty — never null
```

| Method | Signature | Returns |
|--------|-----------|---------|
| `row` | `row(sql, params?)` | First matching row as an object, or `null` |
| `rows` | `rows(sql, params?)` | Array of row objects (empty array when none) |

Row objects map column names to values. `params` is an array bound to `?` placeholders in order — always prefer placeholders over string interpolation (no escaping bugs, no injection).

## Writing: `exec` / `execNoArgs`

```js
db.exec("INSERT INTO notes (text) VALUES (?)", ["buy milk"]);
db.exec("UPDATE notes SET text = ? WHERE id = ?", ["buy oat milk", 1]);
db.exec("DELETE FROM notes WHERE id = ?", [1]);
db.execNoArgs("CREATE INDEX IF NOT EXISTS idx_notes_id ON notes (id)");
```

| Method | Signature | Returns |
|--------|-----------|---------|
| `exec` | `exec(sql, params?)` | `undefined` — throws with the SQLite error message on failure |
| `execNoArgs` | `execNoArgs(sql)` | Same, for statements without parameters (schema, pragmas, indexes) |

SQL errors throw — a bad statement never fails silently:

```js
try {
  db.exec("INSERT INTO missing_table VALUES (?)", [1]);
} catch (e) {
  console.error("write failed:", e.message); // no such table: missing_table
}
```

## Introspection: `changes` / `lastInsertRowId`

Both are **methods** — call them with parentheses, right after the write:

```js
db.exec("INSERT INTO notes (text) VALUES (?)", ["eggs"]);
console.log(db.lastInsertRowId()); // 2

db.exec("UPDATE notes SET text = ? WHERE id < ?", ["x", 100]);
console.log(db.changes()); // rows touched by that UPDATE
```

| Method | Returns |
|--------|---------|
| `lastInsertRowId()` | Rowid of the last successful INSERT on this handle |
| `changes()` | Rows modified by the last write statement |

> **Caution:** `db.lastInsertRowId` without `()` is the function object, not the id. This bites in `Response.json({ id: db.lastInsertRowId })` — always write `db.lastInsertRowId()`.

## Transactions: `transaction(fn)`

```js
db.transaction(() => {
  db.exec("INSERT INTO accounts (name, bal) VALUES (?, ?)", ["a", 100]);
  db.exec("INSERT INTO accounts (name, bal) VALUES (?, ?)", ["b", 100]);
});
```

Semantics: `BEGIN`, then your function runs (called with the db as `this`, no arguments). Throw inside → `ROLLBACK` and the error propagates. Return cleanly → `COMMIT`. The return value of `transaction()` is whatever your function returned:

```js
const id = db.transaction(() => {
  db.exec("INSERT INTO notes (text) VALUES (?)", ["atomic"]);
  return db.lastInsertRowId();
});
console.log(id);
```

Failed transfer rolls everything back — no half-writes:

```js
try {
  db.transaction(() => {
    db.exec("UPDATE accounts SET bal = bal - 50 WHERE name = ?", ["a"]);
    throw new Error("insufficient funds"); // -> ROLLBACK
  });
} catch (e) {
  console.log("aborted:", e.message, "| a still has:", db.row("SELECT bal FROM accounts WHERE name = ?", ["a"]).bal);
}
```

## Tuning: `busyTimeout` / `close`

```js
db.busyTimeout(10000); // wait up to 10s on locked tables (default 5000)
db.close();            // release the handle — queries after this throw
```

Raise the timeout when workers or concurrent writers contend; lower it to fail fast on deadlock-prone flows.

## Practical example: notes API on disk

```js
// server.js
const db = Database.open("notes.db");
db.execNoArgs(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL
)`);

http.serve({ port: 3000 }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  if (path === "/notes" && method === "GET") {
    return Response.json(db.rows("SELECT id, text FROM notes ORDER BY id"));
  }
  if (path === "/notes" && method === "POST") {
    const data = JSON.parse(body || "{}");
    if (!data.text) return Response.json({ error: "text is required" }, { status: 400 });
    const id = db.transaction(() => {
      db.exec("INSERT INTO notes (text) VALUES (?)", [data.text]);
      return db.lastInsertRowId();
    });
    return Response.json(db.row("SELECT id, text FROM notes WHERE id = ?", [id]), { status: 201 });
  }
  return new Response("not found", { status: 404 });
});
```

```sh
ff server.js
curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}
curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

## Troubleshooting

**`no such table: x`** — the `execNoArgs(CREATE TABLE …)` never ran (fresh cwd? different `open` path?). Paths are cwd-relative — log `process.cwd()` when in doubt.

**`database is locked`** — contention beat the busy timeout. Raise `db.busyTimeout(ms)`, shorten write transactions, or serialize writers through one handle.

**`id` comes back as source text in JSON** — you passed `db.lastInsertRowId` instead of calling `db.lastInsertRowId()`. Add the parens.

**Queries after `close()` throw** — by design. Open one handle per process (or per worker) and close only at shutdown.

**`transaction requires a function argument`** — you passed a non-function (e.g. the *result* of calling it). Pass the closure: `db.transaction(() => { … })`.
