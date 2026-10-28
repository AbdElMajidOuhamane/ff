---
title: PostgreSQL API
description: Native Postgres client — connect, query, parameter types, decoding, errors, transactions.
order: 5
---

# PostgreSQL API

`SQL` (and the ready-made `sql`) is global — no import, no package. Native Zig client, extended protocol, lazy pool of up to 10 connections.

## Permissions

Postgres is a network database, so connection setup needs `--allow-net`:

| Operation | Needs |
|---|---|
| `new SQL(dsn)` | `--allow-net=<host>:<port>` — checked in the constructor |
| Global `sql` (first use) | The same net grant, plus `--allow-env` for any `PG_TEST_DSN` / `DATABASE_URL` / `PG*` variables it should read |
| `sql.connect()` | Net grant on the configured host and port |

```sh
ff todos.js --allow-net=127.0.0.1:5432
```

- The check uses the literal host from the DSN. `localhost` and `127.0.0.1`
  are different scopes; there is no DNS matching.
- The default port is `5432` when the DSN omits one, and that is the port
  checked. `postgres://user:pass@db.example.com/app` needs
  `--allow-net=db.example.com:5432`.
- IPv6 hosts with a port need brackets in the flag:
  `--allow-net=[::1]:5432`.
- A scope without a port matches any port: `--allow-net=db.example.com`.

### Global `sql` and environment permission

The global `sql` reads configuration **through the permission filter**, not
through `process.env`. A variable that `--allow-env` does not grant is silently
ignored, and the next source is tried:

```text
PG_TEST_DSN → DATABASE_URL → PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE → defaults
```

```sh
# Use an env DSN:
ff app.js --allow-env=PG_TEST_DSN --allow-net=db.example.com:5432

# Use PG* pieces:
ff app.js \
  --allow-env=PGHOST,PGPORT,PGUSER,PGPASSWORD,PGDATABASE \
  --allow-net=db.example.com:5432

# No env grant: falls back to 127.0.0.1:5432
ff app.js --allow-net=127.0.0.1:5432
```

The defaults are host `127.0.0.1`, port `5432`, user `postgres`, empty
password, database `postgres`.

> **Gotcha:** a missing `--allow-env` does **not** raise `PermissionDenied` for
> the variable. It quietly falls through to the default host, which can look
> like "connection refused" rather than a permissions problem.

### Denial shapes

`new SQL(dsn)` checks eagerly and names the host:

```js
try {
  new SQL("postgres://u:p@127.0.0.1:5432/app");
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // SQL requires --allow-net for '127.0.0.1:5432'
}
```

The global pool is built lazily, on first use, and its denial message is
generic:

```js
try {
  await sql`SELECT 1`;
} catch (e) {
  console.error(e.message); // sql requires --allow-net for 'configured host'
}
```

`sql.unsafe`, `sql.begin`, and `sql.connect` use the same generic
`'configured host'` detail with their own API name. They do not print the
actual host, so check the DSN and your `--allow-net` scope when debugging.

Full model: [Permissions](/docs/concepts/permissions).

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
ff todos.js --allow-net=127.0.0.1:5432
```

## `new SQL(dsn)` / global `sql`

```js
const sql = new SQL("postgres://user:pass@127.0.0.1:5432/app");
await sql.connect(); // optional: probe with SELECT 1, rejects if unreachable
```

`new SQL(dsn)` builds a pool around that DSN and checks its host/port
immediately. The global `sql` is the same API preconfigured from the
environment — checked in order: `PG_TEST_DSN`, `DATABASE_URL`, then `PGHOST` /
`PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`, then defaults
(`127.0.0.1:5432`, user `postgres`, database `postgres`). Only variables
granted by `--allow-env` are visible to this lookup.

Connections are lazy: the first query opens them, idle connections are reused, and the pool caps at 10. For the global `sql`, that first query is also when the net permission check runs.

> **Caution:** With no DSN argument and no granted environment, the global
> `sql` points at `127.0.0.1:5432` and needs
> `--allow-net=127.0.0.1:5432`. If that host is not running Postgres, the query
> rejects with a connection error. Export an allowed DSN — or pass one to
> `new SQL(dsn)` — to point somewhere else.

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

Permission failures are different: they are local `Error` objects with
`name: "PermissionDenied"` and `code: "PERMISSION_DENIED"`, thrown before a
connection is attempted. They have no SQLSTATE `severity` or `detail`.

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
PG_TEST_DSN='postgres://fairyfly:fairyfly@127.0.0.1:5432/fairyfly' \
ff server.js \
  --allow-env=PG_TEST_DSN \
  --allow-net=127.0.0.1:5432,0.0.0.0:3000
curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}
curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

The DSN is read through `process.env`, so `--allow-env=PG_TEST_DSN` is
required. The net grant covers both the database connection and the HTTP
listener.

Full working app: `examples/todo-app/` (CRUD + jsonb/arrays + transactions). Script tour: `examples/sql-todo.js`.

## Troubleshooting

**`PermissionDenied: sql requires --allow-net for 'configured host'`** — the
global pool cannot reach the configured host. Add the host and port to
`--allow-net`. The message does not name the host, so check which config source
won: `PG_TEST_DSN`, `DATABASE_URL`, `PG*`, or the `127.0.0.1:5432` default.

**`PermissionDenied: SQL requires --allow-net for 'host:port'`** — same issue
from the `new SQL(dsn)` constructor. The message names the checked host; add
that exact scope. `localhost` will not match `127.0.0.1`.

**`PG_TEST_DSN` seems ignored** — `--allow-env=PG_TEST_DSN` is missing. The
global `sql` silently falls through to `DATABASE_URL`, the `PG*` variables, or
the defaults. `process.env.PG_TEST_DSN` is also `undefined` without the grant.

**`TypeError: no database pool`** — the global pool could not be built, for
example because an allowed DSN variable is malformed. Fix the DSN or pass one
to `new SQL(dsn)`.

**Connection refused** — Postgres isn't listening (Docker not up? `docker compose up -d`), or the host/port in the DSN is wrong. If you expected an env DSN but got the default, check `--allow-env`.

**`password authentication failed`** — credentials in the DSN don't match the server. Check `PGUSER` / `PGPASSWORD`; environment variables override nothing once a DSN argument is passed.

**`relation "x" does not exist`** — the migration never ran on this database (wrong database name? fresh server?). Run the `CREATE TABLE` before the queries.

**`transaction busy`** — two queries were fired inside one transaction without awaiting the first. Serialize them: `await` each statement.

**`no operator matches` / type errors at the server** — a parameter was encoded as a different type than the column expects (e.g. `text` param against an `integer` column). Cast in the SQL (`$1::int`) or pass the right JS type.

**Queries after `sql.close()` fail** — by design. Close only at shutdown, one pool per process (per worker).

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [SQLite API](/docs/api/sqlite) — embedded, filesystem-gated database
- [API overview](/docs/api/overview) — every injected global
- [Limitations](/docs/reference/limitations) — every hard cap
