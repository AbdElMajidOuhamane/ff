import { check, done } from "./lib.mjs";

const dsn = process.env.PG_TEST_DSN;
if (!dsn) {
    console.log("[todo] skip: PG_TEST_DSN not set");
    process.exit(0);
}

const sql = globalThis.sql;

// Full CRUD todo list — exercises typed params, NULL, RETURNING,
// constraints (.code), concurrency, and recovery on the native client.

sql.unsafe("DROP TABLE IF EXISTS ff_todos")
    .then(() => sql.unsafe(
        "CREATE TABLE ff_todos (" +
        "id serial PRIMARY KEY," +
        "title text NOT NULL," +
        "done boolean NOT NULL DEFAULT false," +
        "priority int," +
        "note text" +
        ")"
    ))
    .then(() => {
        // CREATE + single insert with mixed typed params
        return sql`INSERT INTO ff_todos(title, done, priority, note) VALUES (${"ship sql"}, ${false}, ${1}, ${"phase 2"}) RETURNING id, title, done, priority, note`;
    })
    .then((rows) => {
        check("insert returning id", rows.length === 1 && typeof rows[0].id === "number");
        check("insert title", rows[0].title === "ship sql");
        check("insert bool false", rows[0].done === false);
        check("insert int priority", rows[0].priority === 1);
        check("insert note", rows[0].note === "phase 2");
        const id = rows[0].id;

        // NULL param round-trip through an int column
        return sql`INSERT INTO ff_todos(title, priority, note) VALUES (${"null row"}, ${null}, ${null}) RETURNING id, priority, note`
            .then((r2) => {
                check("null priority", r2[0].priority === null);
                check("null note", r2[0].note === null);
                return id;
            });
    })
    .then((id) => {
        // SELECT by typed int param
        return sql`SELECT id, title, done FROM ff_todos WHERE id = ${id}`
            .then((rows) => {
                check("select by id", rows.length === 1 && rows[0].id === id);
                check("select title", rows[0].title === "ship sql");
                return id;
            });
    })
    .then((id) => {
        // UPDATE with bool + int params, RETURNING
        return sql`UPDATE ff_todos SET done = ${true}, priority = ${9} WHERE id = ${id} RETURNING id, done, priority`
            .then((rows) => {
                check("update returns row", rows.length === 1);
                check("update done true", rows[0].done === true);
                check("update priority 9", rows[0].priority === 9);
                return id;
            });
    })
    .then(() => {
        // WHERE on typed bool param
        return sql`SELECT count(*)::int AS n FROM ff_todos WHERE done = ${true}`;
    })
    .then((rows) => {
        check("where bool count", rows[0].n === 1);

        // String param with quote escaping
        return sql`SELECT ${"it's a todo"} AS s`;
    })
    .then((rows) => {
        check("quoted string param", rows[0].s === "it's a todo");

        // Constraint violation → .code sqlstate
        return sql`INSERT INTO ff_todos(id, title) VALUES (${1}, ${"dup"})`.then(() => {
            check("dup should reject", false);
        }, (err) => {
            check("dup rejects", err instanceof Error);
            check("dup sqlstate 23505", err.code === "23505");
            check("dup has severity", typeof err.severity === "string");
        });
    })
    .then(() => {
        // NOT NULL constraint via param
        return sql`INSERT INTO ff_todos(title) VALUES (${null})`.then(() => {
            check("notnull should reject", false);
        }, (err) => {
            check("notnull rejects", err instanceof Error);
            check("notnull sqlstate", err.code === "23502");
        });
    })
    .then(() => {
        // Recovery after errors + concurrent queries
        return Promise.all([
            sql`SELECT 10 AS a`,
            sql`SELECT 20 AS b`,
            sql`SELECT 30 AS c`,
        ]);
    })
    .then((results) => {
        check("concurrent a", results[0][0].a === 10);
        check("concurrent b", results[1][0].b === 20);
        check("concurrent c", results[2][0].c === 30);

        // unsafe with typed param
        return sql.unsafe("SELECT $1::int AS n, $2::text AS t", [42, "ok"]);
    })
    .then((rows) => {
        check("unsafe int", rows[0].n === 42);
        check("unsafe text", rows[0].t === "ok");

        // DELETE all, RETURNING count
        return sql`DELETE FROM ff_todos`;
    })
    .then(() => {
        return sql`SELECT count(*)::int AS n FROM ff_todos`;
    })
    .then((rows) => {
        check("deleted all", rows[0].n === 0);
        return sql.unsafe("DROP TABLE ff_todos");
    })
    .then(() => {
        // still alive after DROP
        return sql`SELECT 1 AS ok`;
    })
    .then((rows) => {
        check("recovers after drop", rows[0].ok === 1);
        sql.close();
        done("todo");
    })
    .catch((err) => {
        console.log("FAIL: exception", err);
        try { sql.close(); } catch (e) {}
        done("todo");
    });
