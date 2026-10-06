---
title: PostgreSQL API
description: Native Postgres client — connect, query, parameter types, decoding, errors, transactions.
order: 5
---

# PostgreSQL API

`SQL` (and the ready-made `sql`) is global — no import, no package. Native Zig client, extended protocol, lazy pool of up to 10 connections.

## Quick look

```js
// todos.js
const sql = new SQL("postgres://fairyfly:fairyfly@127.0.0.1:5432/fairyfly");

await sql`CREATE TABLE IF NOT EXISTS todos (
  id serial PRIMARY KEY,
  title text NOT NULL,
  done boolean NOT NULL DEFAULT false
)`;

await sql`INSERT INTO todos(title) VALUES (${"buy milk"})`;
const rows = await sql`SELECT id, title, done FROM todos WHERE done = ${false}`;
console.log(rows);
// [ { id: 1, title: "buy milk", done: false } ]

sql.close();
```

```sh
ff todos.js
```

## `new SQL(dsn)` / global `sql`

```js
const sql = new SQL("postgres://user:pass@127.0.0.1:5432/app");
await sql.connect(); // optional: probe with SELECT 1, rejects if unreachable
```

`new SQL(dsn)` builds a pool around that DSN. The global `sql` is the same API preconfigured from the environment — checked in order: `PG_TEST_DSN`, `DATABASE_URL`, then `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`, then defaults (`127.0.0.1:5432`, user `postgres`).

Connections are lazy: the first query opens them, idle connections are reused, and the pool caps at 10.

> **Caution:** With no DSN argument and no environment set, queries reject with `TypeError: no database pool`. Export `PG_TEST_DSN` (or pass the DSN) before running.

## Reading and writing: tag / `unsafe`

```js
// Tagged template — ${} values become parameters. Always an array of row objects.
const todos = await sql`SELECT * FROM todos WHERE id = ${id}`;

// unsafe() — $N placeholders, for dynamic SQL shapes.
const open = await sql.unsafe(
  "SELECT id, title FROM todos WHERE done = $1 ORDER BY id LIMIT $2",
  [false, 10],
);

// Writes read the same way — RETURNING gives rows back.
const created = await sql`INSERT INTO todos(title) VALUES (${"eggs"}) RETURNING id`;
console.log(created[0].id);
```

| Call | Signature | Returns |
|------|-----------|---------|
| tag | `` sql`...` `` | `Promise<object[]>` — empty array when no rows |
| `unsafe` | `sql.unsafe(text, params?)` | Same, with `$N` placeholders bound in order |

Rows map column names to values; `NULL` is `null`. Always prefer placeholders over string interpolation (no escaping bugs, no injection) — identifiers (table/column names) must never come from input, only values travel as params.

## Parameter types

| JS value | Sent as |
|----------|---------|
| `null` / `undefined` | `NULL` |
| `boolean` | `bool` |
| `number` (safe integer) | `int8` |
| `number` (float) | `float8` |
| `string` | `text` |
| `bigint` | `int8` |
| `Array` | typed array literal (`int8[]`, `float8[]`, `bool[]`, `text[]`; nested OK) |
| plain object (incl. `Date`) | `json` |
| `Uint8Array` | `bytea` |

Arrays and objects round-trip jsonb and `text[]` columns without a manual `JSON.stringify`:

```js
await sql`INSERT INTO todos(title, meta, tags)
  VALUES (${"a"}, ${{ store: "corner" }}, ${["errand", "work"]})`;
```

## Result decoding

| PostgreSQL type | JS value |
|-----------------|----------|
| `int2` / `int4` / `int8` within ±2⁵³ | `number` |
| `int8` outside ±2⁵³ | `bigint` |
| `float4` / `float8` | `number` |
| `bool` | `boolean` |
| `text` / `varchar` / `char` | `string` |
| `bytea` | `Uint8Array` |
| `json` / `jsonb` | parsed value (object, array, …) |
| array types | JS array (incl. nested) |
| `NULL` | `null` |
| anything else (timestamps, `numeric`, …) | `string` |

## Errors

Failures reject the promise — await inside `try/catch`:

```js
try {
  await sql`INSERT INTO todos(id, title) VALUES (${1}, ${"dup"})`;
} catch (err) {
  console.log(err.code);      // "23505"
  console.log(err.severity);  // "ERROR"
  console.log(err.message);   // server message
}
```

| Field | Meaning |
|-------|---------|
| `code` | SQLSTATE (e.g. `23505` unique violation, `23503` FK violation, `42P01` missing table) |
| `severity` | `ERROR` / `FATAL` / … |
| `message` | Server message text |
| `detail` | Extra context when the server sends it |

## Transactions: `begin` + `transaction(fn)`

```js
// Userland helper over native begin/commit/rollback — copy this into your app.
function transaction(fn) {
  return sql.begin().then((tx) => fn(tx).then(
    (r) => tx.commit().then(() => r),
    (e) => tx.rollback().then(() => { throw e; }),
  ));
}

await transaction(async (tx) => {
  await tx`UPDATE accounts SET bal = bal - 50 WHERE name = ${"a"}`;
  await tx`UPDATE accounts SET bal = bal + 50 WHERE name = ${"b"}`;
});
// Committed together; any failure rolls everything back.
```

A transaction pins one connection: the tag, `tx.unsafe(...)`, `tx.commit()`, and `tx.rollback()` all run on it. Await each query before starting the next — a transaction runs one query at a time, and using a finished transaction fails.

> **Caution:** Don't interleave a transaction with plain `sql` queries and assume they share state — outside queries use other pool connections and won't see uncommitted rows.

## Tuning: `close`

```js
sql.close(); // release all connections — queries after this fail
```

Call it at shutdown (or nowhere — the process exit closes sockets anyway).

## Practical example: notes API on Postgres

```js
// server.js
const sql = new SQL(process.env.PG_TEST_DSN);
await sql`CREATE TABLE IF NOT EXISTS notes (
  id serial PRIMARY KEY,
  text text NOT NULL
)`;

http.serve({ port: 3000 }, async (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  if (path === "/notes" && method === "GET") {
    return Response.json(await sql`SELECT id, text FROM notes ORDER BY id`);
  }
  if (path === "/notes" && method === "POST") {
    const data = JSON.parse(body || "{}");
    if (!data.text) return Response.json({ error: "text is required" }, { status: 400 });
    const rows = await sql`INSERT INTO notes(text) VALUES (${data.text}) RETURNING id, text`;
    return Response.json(rows[0], { status: 201 });
  }
  return new Response("not found", { status: 404 });
});
```

```sh
PG_TEST_DSN='postgres://fairyfly:fairyfly@127.0.0.1:5432/fairyfly' ff server.js
curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}
curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

Full working app: `examples/todo-app/` (CRUD + jsonb/arrays + transactions). Script tour: `examples/sql-todo.js`.

## Troubleshooting

**`TypeError: no database pool`** — no DSN argument and no `PG_TEST_DSN` / `DATABASE_URL` / `PG*` variables. Export one, or use `new SQL(dsn)`.

**Connection refused** — Postgres isn't listening (Docker not up? `docker compose up -d`), or the host/port in the DSN is wrong.

**`password authentication failed`** — credentials in the DSN don't match the server. Check `PGUSER` / `PGPASSWORD`; environment variables override nothing once a DSN argument is passed.

**`relation "x" does not exist`** — the migration never ran on this database (wrong database name? fresh server?). Run the `CREATE TABLE` before the queries.

**`transaction busy`** — two queries were fired inside one transaction without awaiting the first. Serialize them: `await` each statement.

**`no operator matches` / type errors at the server** — a parameter was encoded as a different type than the column expects (e.g. `text` param against an `integer` column). Cast in the SQL (`$1::int`) or pass the right JS type.

**Queries after `sql.close()` fail** — by design. Close only at shutdown, one pool per process (per worker).
