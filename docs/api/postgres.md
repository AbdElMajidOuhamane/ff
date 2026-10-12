---
title: PostgreSQL API
description: Native Postgres client — connect, query, parameter types, decoding, errors, transactions.
order: 5
---

# PostgreSQL API

`SQL` (the class) and `sql` (a ready-made instance built from the environment) are global — no import, no package. The client speaks the Postgres **extended query protocol** (Parse/Bind/Describe/Execute) over a lazy pool of up to **10** connections.

## Quick look

```js
// todos.mjs
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
ff todos.mjs
```

> Plain `.js` files are classic scripts (top-level `await` is a syntax error). The examples here use `.mjs`; in a `.js` file wrap the body in `(async () => { … })()`.

## The `sql` global and the `SQL` class

```js
// Global sql — pool configured from the environment.
await sql`SELECT 1`;

// Your own pool, from a DSN string…
const db = new SQL("postgres://user:pass@127.0.0.1:5432/app");
// …or from a config object.
const db2 = new SQL({ host: "127.0.0.1", port: 5432, user: "u", password: "p", database: "app", max: 20 });
```

Both the global `sql` and any `SQL` instance expose the same members:

| Member | Signature | Notes |
|--------|-----------|-------|
| tag | `` db`…${v}…` `` | Tagged template; `${}` values become `$N` parameters |
| `unsafe` | `db.unsafe(text, params?)` | Raw SQL with `$N` placeholders |
| `begin` | `db.begin()` | `Promise<Tx>` — starts a transaction |
| `connect` | `db.connect()` | `Promise<object[]>` — eager probe (`SELECT 1`) |
| `close` | `db.close()` | Synchronously closes the pool |

`SQL` is a **constructor** — call it with `new`. Calling `SQL(dsn)` without `new` throws. The global `sql` is itself a callable function (the tag), with `unsafe` / `connect` / `begin` / `close` attached.

### `new SQL(source?)`

- **String** — a DSN: `scheme://[user[:password]@]host[:port][/database]`.
- **Object** — `{ host, port, user, password, database, max }`. `port` is clamped to `1..65535`, `max` to `1..100`.
- **Nothing** — the built-in defaults: `127.0.0.1:5432`, user `postgres`, empty password, database `postgres`, `max` 10.

A string that isn't a valid DSN throws `TypeError: invalid database URL`.

### The global `sql` and environment variables

The global `sql` is built lazily on first use, reading the environment in order:

1. `PG_TEST_DSN`
2. `DATABASE_URL`
3. `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`
4. defaults `127.0.0.1:5432`, user `postgres`, empty password, database `postgres`

`new SQL(dsn)` ignores the environment entirely.

> **Caution:** With no DSN and no environment variables the global `sql` **still works** — it points at the built-in default (localhost, user `postgres`, no password). The first query then rejects with a connection `Error` whose `.code` is `"08006"`. A synchronous `TypeError` (`no database pool`, or the DSN error name) appears only when pool creation itself fails — e.g. a malformed `PG_TEST_DSN`, from `sql.unsafe` / `sql.begin` / `sql.connect`.

### DSN details

- The scheme (`postgres://` / `postgresql://`) is required; only `user:password@`, `host`, `port`, and `/database` are parsed.
- IPv6 hosts must be bracketed: `postgres://[::1]:5432/app`.
- **No TLS.** The client never sends an SSLRequest and connects in plaintext; `sslmode` is not honored. Query-string parameters (`?sslmode=require`) are not parsed — they would be folded into the database name.
- The DSN is **not** percent-decoded, so avoid reserved characters in the password (a literal `@` splits at the wrong place).

Connections are lazy: the first query opens them, idle connections are reused, and the pool stacks at most `max` (10 by default). When every connection is busy, further queries **queue** on the pool rather than failing.

## Reading and writing: tag / `unsafe`

```js
// Tagged template — each ${} value becomes a $N parameter.
const todos = await sql`SELECT * FROM todos WHERE id = ${id}`;

// unsafe() — write $N yourself, for dynamic SQL shapes.
const open = await sql.unsafe(
  "SELECT id, title FROM todos WHERE done = $1 ORDER BY id LIMIT $2",
  [false, 10],
);

// Writes read the same way — RETURNING gives rows back.
const created = await sql`INSERT INTO todos(title) VALUES (${"eggs"}) RETURNING id`;
console.log(created[0].id);
```

| Call | Signature | Resolves to |
|------|-----------|-------------|
| tag | `` sql`…` `` | `object[]` — one object per row (**empty array** when none) |
| `unsafe` | `sql.unsafe(text, params?)` | The same array |

Every call resolves to an **array of row objects**, even writes: `INSERT`/`UPDATE`/`DELETE` without `RETURNING` resolve to `[]`. There is **no `rowCount`** property — use `RETURNING` when you need affected rows back.

Misuse throws **synchronously**, before any promise exists:

- `sql.unsafe(123)` → `TypeError: sql.unsafe requires a string`.
- Calling the tag with a non-template argument → `TypeError: sql must be used as a template tag`.

A single query string can contain only **one** command (the extended protocol prepares one statement); a string with multiple `;`-separated statements is rejected by the server. `COPY` is **not supported** — use `INSERT`/`UPDATE` for bulk loads.

Rows map **column name → value**; SQL `NULL` is `null`. Always prefer placeholders over string interpolation (no escaping bugs, no injection) — identifiers (table/column names) must never come from input, only values travel as parameters.

## Parameter types

Each `${}` value (or `unsafe` array element) is encoded with an explicit Postgres type OID:

| JS value | Sent as | OID |
|----------|---------|-----|
| `null` / `undefined` | `NULL` | 0 |
| `boolean` | `bool` | 16 |
| `number` (safe integer) | `int8` | 20 |
| `number` (fractional / `NaN` / `Infinity`) | `float8` | 701 |
| `bigint` | `int8`, as exact decimal text | 20 |
| `string` | `text` | 25 |
| `Uint8Array` | `bytea` (hex `\x…`) | 17 |
| `Array` | typed array literal (see below) | 1016 / 1022 / 1000 / 1009 |
| plain object (incl. `Date`) | `json` via `JSON.stringify` | 114 |

Arrays infer one element type for the whole (recursively scanned) array:

| Element type | Array OID |
|--------------|-----------|
| integers / bigints | `int8[]` (1016) |
| floats | `float8[]` (1022) |
| booleans | `bool[]` (1000) |
| anything else / mixed | `text[]` (1009) |

Nesting is supported to a depth of 8. JSON arrays arrive as Postgres arrays, **not** jsonb — to store a JSON array, pass a `JSON.stringify([...])` string or wrap it in an object.

```js
await sql`INSERT INTO todos(title, meta, tags)
  VALUES (${"a"}, ${{ store: "corner" }}, ${["errand", "work"]})`;
```

> **Caution:** Use `Uint8Array` for `bytea`. A raw `ArrayBuffer` is not recognized as binary and is encoded as `json`.

## Result decoding

Column values are decoded from the server's text format by type OID:

| PostgreSQL type | JS value |
|-----------------|----------|
| `int2` / `int4` / `int8` within ±2^53 | `number` |
| `int8` outside ±2^53 | `bigint` |
| `float4` / `float8` | `number` |
| `bool` | `boolean` |
| `text` / `varchar` / `char` / `name` | `string` |
| `bytea` | `Uint8Array` (a copy) |
| `json` / `jsonb` | parsed value (object, array, …); raw string if it can't be parsed |
| array types | JS array (nested arrays decode recursively) |
| `NULL` | `null` |
| anything else (timestamps, `numeric`, `uuid`, enums, …) | `string` |

Known array OIDs decode their elements with the rules above (`_int8` → numbers/bigints, `_bytea` → `Uint8Array[]`, `_json` / `_jsonb` → parsed values, `_numeric` → strings, …). Any OID the client doesn't recognize — including the whole value of an unknown **array** type — comes back as a `string`.

## Errors

Failed queries **reject** the promise — `await` inside `try/catch`:

```js
try {
  await sql`INSERT INTO todos(id, title) VALUES (${1}, ${"dup"})`;
} catch (err) {
  console.log(err.code);     // "23505"
  console.log(err.severity); // "ERROR"
  console.log(err.message);  // server message
  console.log(err.detail);   // extra context, when the server sends it
}
```

Rejections are real `Error` instances (`err instanceof Error` is `true`) with these own properties:

| Field | Meaning |
|-------|---------|
| `code` | SQLSTATE (`23505` unique violation, `23503` FK violation, `42P01` missing table, …) |
| `severity` | Server severity (`ERROR`, `FATAL`, …) |
| `message` | Server message text |
| `detail` | Extra context, present only when the server sends it |

Client-side failures reject the same way, with `severity: "ERROR"` and `code: "08006"` — for example `connection failed`, `failed to start connection`, `failed to send query`, `pool is closed`, `transaction closed`, and `transaction busy`.

Encoding/misuse errors are different: they throw a **synchronous `TypeError`** (no promise is created), e.g. `cannot encode query parameter`.

## Transactions: `begin()` + `Tx`

`sql.begin()` resolves to a `Tx` object that **pins one connection**. The `Tx` is itself callable as a tag and exposes `unsafe`, `commit`, and `rollback`:

| Member | Signature | Notes |
|--------|-----------|-------|
| tag | `` tx`…` `` | Runs on the pinned connection |
| `unsafe` | `tx.unsafe(text, params?)` | `$N` parameters |
| `commit` | `tx.commit()` | `Promise<object[]>` |
| `rollback` | `tx.rollback()` | `Promise<object[]>` |

```js
const tx = await sql.begin();
try {
  await tx`UPDATE accounts SET bal = bal - 50 WHERE name = ${"a"}`;
  await tx`UPDATE accounts SET bal = bal + 50 WHERE name = ${"b"}`;
  await tx.commit();
} catch (e) {
  await tx.rollback();
  throw e;
}
```

Or wrap it in a helper — this file is runnable:

```js
// tx-demo.mjs
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

Rules:

- A transaction runs **one query at a time**. Firing a second query before the first resolves rejects with `transaction busy` (`code: "08006"`) — `await` each statement.
- After `commit()` / `rollback()` the `Tx` is finished; using it again throws `TypeError: transaction is closed`.
- `begin()`, `commit()`, `rollback()` resolve with the (usually empty) rows array.

> **Caution:** Don't interleave a transaction with plain `sql` queries and assume they share state — outside queries use other pool connections and won't see uncommitted rows.

## Tuning: `close`

```js
sql.close(); // release all connections — synchronous, returns undefined
```

On a `SQL` **instance**, `close()` closes that pool permanently: later queries reject with `pool is closed`. On the global `sql`, `close()` releases the default pool, but the next query lazily builds a fresh one from the environment. Call it at shutdown (or nowhere — process exit closes the sockets anyway).

## Practical example: notes API on Postgres

```js
// server.mjs
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
PG_TEST_DSN='postgres://fairyfly:fairyfly@127.0.0.1:5432/fairyfly' ff server.mjs
curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}
curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

## Troubleshooting

**Connection `Error` with `code: "08006"`** — the pool couldn't connect (bad host/port, server down, bad credentials). When no DSN or `PG*` variables are set, the global `sql` targets `127.0.0.1:5432` as user `postgres`.

**`TypeError: no database pool`** — pool creation itself failed (typically a malformed `PG_TEST_DSN`), surfaced by `sql.unsafe` / `sql.begin` / `sql.connect`.

**`password authentication failed`** — credentials don't match the server. Check `PGUSER` / `PGPASSWORD`, or the DSN.

**`relation "x" does not exist`** — the migration never ran on this database (wrong database name? fresh server?). Run the `CREATE TABLE` before the queries.

**`transaction busy`** — two queries fired inside one transaction without awaiting the first. `await` each statement.

**`transaction is closed`** — the `Tx` was already committed or rolled back. Create a new one with `sql.begin()`.

**`cannot insert multiple commands into a prepared statement`** — the query contains more than one `;`-separated statement. Send one at a time.

**`no operator matches` / type errors at the server** — a parameter was encoded as a different type than the column expects (e.g. a `text` param against an `integer` column). Cast in the SQL (`$1::int`) or pass the right JS type.

**`sslmode=require` seems ignored** — it is: the client is plaintext-only and doesn't parse DSN query parameters.
