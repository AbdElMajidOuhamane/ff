---
title: SQLite API
description: Database reference — open, query, write, transactions, and introspection.
order: 3
---

# SQLite API

`Database` is global — no import, no package. It is a namespace object with a single factory, `Database.open(path)`, which returns a **handle**. Every call on a handle is **synchronous** — there are no promises, no callbacks, no async variants.

Each handle runs in WAL mode with a **5000 ms** busy timeout by default, and identical SQL is cached per handle (up to 64 prepared statements) so repeated statements skip re-parsing.

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

## Full handle API

| Member | Signature | Returns |
|--------|-----------|---------|
| `Database.open` | `open(path)` | A new handle (throws on failure) |
| `row` | `row(sql, params?)` | First matching row object, or `null` |
| `rows` | `rows(sql, params?)` | Array of row objects (empty when none) |
| `exec` | `exec(sql, params?)` | `undefined` |
| `execNoArgs` | `execNoArgs(sql)` | `undefined` |
| `changes` | `changes()` | `number` — rows touched by the last write |
| `lastInsertRowId` | `lastInsertRowId()` | `number` — rowid of the last INSERT |
| `busyTimeout` | `busyTimeout(ms)` | `undefined` |
| `transaction` | `transaction(fn)` | Whatever `fn` returned |
| `close` | `close()` | `undefined` |

There is no `prepare`, `query`, `all`, or `get` — `row` / `rows` / `exec` cover the whole surface.

## `Database.open(path)`

```js
const db = Database.open("app.db");
const mem = Database.open(":memory:");
```

Opens (creating the file when missing) and returns a handle. The `path` is coerced to a string; passing nothing throws `TypeError: Database.open requires a file path`.

Every open:
- opens with `READWRITE | CREATE`,
- runs `PRAGMA journal_mode=WAL` (a no-op for `:memory:` databases),
- sets a **5000 ms** busy timeout.

If the file can't be opened, the SQLite error message is thrown as a **plain string** (`"unable to open database file"`, …).

> **Caution:** The path is relative to the process **cwd**, not the script. `Database.open("app.db")` lands next to where you launched `ff`, not necessarily next to your script. `":memory:"` gives each open its own private, non-persistent database.

> **Note:** `Database` is a namespace object, not a constructor — `typeof Database === "object"`, and `db instanceof Database` is `false`.

## Reading: `row` / `rows`

```js
const one = db.row("SELECT id, text FROM notes WHERE id = ?", [1]);
console.log(one); // { id: 1, text: "buy milk" } — or null when no row matches

const all = db.rows("SELECT id, text FROM notes ORDER BY id");
console.log(all.length); // 0 when empty — never null
```

| Method | Signature | Returns |
|--------|-----------|---------|
| `row` | `row(sql, params?)` | First row as an object, or `null` |
| `rows` | `rows(sql, params?)` | Array of row objects (empty array when none) |

Row objects map **column name → value**. Values are decoded from the SQLite storage class:

| SQLite type | JS value |
|-------------|----------|
| `INTEGER` | `number` (see precision note below) |
| `REAL` | `number` |
| `TEXT` | `string` |
| `BLOB` | `ArrayBuffer` (a copy) |
| `NULL` | `null` |

`params` is bound to `?` placeholders **in order** — always prefer placeholders over string interpolation (no escaping bugs, no injection). `params` can be any array-like (its `length` and numeric indices are read).

## Writing: `exec` / `execNoArgs`

```js
db.exec("INSERT INTO notes (text) VALUES (?)", ["buy milk"]);
db.exec("UPDATE notes SET text = ? WHERE id = ?", ["buy oat milk", 1]);
db.exec("DELETE FROM notes WHERE id = ?", [1]);
db.execNoArgs("CREATE INDEX IF NOT EXISTS idx_notes_id ON notes (id)");
```

| Method | Signature | Returns |
|--------|-----------|---------|
| `exec` | `exec(sql, params?)` | `undefined` |
| `execNoArgs` | `execNoArgs(sql)` | `undefined` |

`exec` prepares **one** statement and runs it to completion. `execNoArgs` runs the whole string through SQLite's `exec`, so **only `execNoArgs` runs multiple `;`-separated statements**:

```js
// Only the CREATE runs — the INSERT after it is silently dropped.
db.exec("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)");

// Both run:
db.execNoArgs("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)");
```

> **Caution:** `exec` with a multi-statement string is a silent footgun — the tail after the first statement is never executed. Use `execNoArgs` for schema scripts.

SQL errors **throw** — a bad statement never fails silently. The thrown value is a **plain string**, not an `Error`:

```js
try {
  db.exec("INSERT INTO missing_table VALUES (?)", [1]);
} catch (e) {
  console.error("write failed:", String(e)); // no such table: missing_table
  console.error(typeof e, e instanceof Error); // "string" false — e.message is undefined
}
```

Passing more array elements than there are `?` placeholders trips SQLite's range check and throws a plain string too; passing fewer binds the missing ones as `NULL`. Missing/invalid arguments (e.g. `exec()` with no SQL) throw a real `TypeError`.

## Parameter binding

Values in the `params` array are bound by position. Each JS value maps to a SQLite binding:

| JS value | Bound as |
|----------|----------|
| `number` | `INTEGER` when the engine tags it as an int (32-bit range), otherwise `REAL` |
| `boolean` | `INTEGER` `0` / `1` (SQLite has no boolean type) |
| `string` | `TEXT` |
| `null` / `undefined` | `NULL` |
| `ArrayBuffer` / `Uint8Array` | `BLOB` (copied) |
| `bigint` | `NULL` — **not supported** |
| any other object (incl. `Date`) | `NULL` |

Prefer `?` placeholders and positional arrays. Named/labeled placeholders are not exposed through the array form.

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
| `changes()` | Rows modified by the last completed INSERT/UPDATE/DELETE (a `SELECT` does not reset it) |

> **Caution:** `db.lastInsertRowId` without `()` is the function object, not the id. This bites in `Response.json({ id: db.lastInsertRowId })` — always write `db.lastInsertRowId()`.

### Integer precision

SQLite stores `INTEGER` as a signed 64-bit value, but it is handed to JS as a `number` — a double. Values beyond **±2^53** therefore lose precision (like every JS integer). Keep such columns as `TEXT` (or read them via a string cast) if you need exact large integers.

## Transactions: `transaction(fn)`

```js
db.transaction(() => {
  db.exec("INSERT INTO accounts (name, bal) VALUES (?, ?)", ["a", 100]);
  db.exec("INSERT INTO accounts (name, bal) VALUES (?, ?)", ["b", 100]);
});
```

Semantics:

- Runs `BEGIN`.
- Calls `fn` **synchronously**, with the handle as `this` and **no arguments**.
- `fn` throws → `ROLLBACK`, and the thrown value propagates out of `transaction()`.
- `fn` returns and `COMMIT` succeeds → `transaction()` returns whatever `fn` returned.
- If `COMMIT` itself fails, the SQLite error message is thrown as a plain string.

```js
const id = db.transaction(function () {
  this.exec("INSERT INTO notes (text) VALUES (?)", ["atomic"]);
  return this.lastInsertRowId();
});
console.log(id);
```

Failed work rolls everything back — no half-writes:

```js
try {
  db.transaction(() => {
    db.exec("UPDATE accounts SET bal = bal - 50 WHERE name = ?", ["a"]);
    throw new Error("insufficient funds"); // -> ROLLBACK
  });
} catch (e) {
  console.log("aborted:", String(e), "| a still has:", db.row("SELECT bal FROM accounts WHERE name = ?", ["a"]).bal);
}
```

> **Caution:** `transaction` is synchronous. If `fn` is `async` (or returns a promise), `transaction()` commits immediately and returns the promise — it does **not** wait for it. Do all writes synchronously inside the callback. Nesting a `transaction()` inside another also fails: SQLite rejects the inner `BEGIN` with a plain-string error.

`transaction` also validates its argument: a non-function throws `TypeError: transaction requires a function argument`.

## Tuning: `busyTimeout` / `close`

```js
db.busyTimeout(10000); // wait up to 10s on locked tables (default 5000)
db.close();            // release the handle — queries after this throw
```

Raise the timeout when workers or concurrent writers contend; lower it to fail fast on deadlock-prone flows. `busyTimeout()` with no argument throws `TypeError: busyTimeout requires a millisecond argument`.

`close()` finalizes the connection and detaches the handle. **Every later call on a closed handle throws `TypeError`** (e.g. `exec: invalid database`), including a second `close()`. The handle is also closed automatically by the GC finalizer if you never call `close()`.

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

**Only the first statement of an `exec` ran** — `exec` compiles a single statement. Use `execNoArgs` for multi-statement schema scripts.

**Caught error has no `.message`** — SQL failures throw plain strings (`typeof e === "string"`), so `e.message` is `undefined` and `e instanceof Error` is `false`. Log `String(e)`. (Pure argument mistakes, e.g. calling `exec()` with no SQL, throw real `TypeError`s.)

**`database is locked`** — contention beat the busy timeout. Raise `db.busyTimeout(ms)`, shorten write transactions, or serialize writers through one handle.

**`id` comes back as source text in JSON** — you passed `db.lastInsertRowId` instead of calling `db.lastInsertRowId()`. Add the parens.

**A big integer is off by a few units** — SQLite `INTEGER` values beyond ±2^53 lose precision on the way to a JS `number`. Store them as `TEXT` and convert explicitly.

**`transaction requires a function argument`** — you passed a non-function (e.g. the *result* of calling it). Pass the closure: `db.transaction(() => { … })`.

**Queries after `close()` throw** — by design (and a second `close()` throws too). Open one handle per process (or per worker) and close only at shutdown.
