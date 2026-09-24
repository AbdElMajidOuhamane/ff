import { check, done } from "./lib.mjs";

const dsn = process.env.PG_TEST_DSN;
if (!dsn) {
    console.log("[sql] skip: PG_TEST_DSN not set");
    process.exit(0);
}

const sql = globalThis.sql;

sql`SELECT 1 AS n`.then((rows) => {
    check("select literal", rows.length === 1 && rows[0].n === 1);
    return sql`SELECT ${42} AS n`;
}).then((rows) => {
    check("int param", rows[0].n === 42);
    return sql`SELECT ${"it's"} AS s`;
}).then((rows) => {
    check("string param", rows[0].s === "it's");
    return sql`SELECT ${null} AS v`.then((r2) => {
        check("null param", r2[0].v === null);
        return sql.unsafe("SELECT $1::int AS a", [7]);
    });
}).then((rows) => {
    check("unsafe param", rows[0].a === 7);
    return sql`INSERT INTO ff_smoke(x) VALUES (${99}) RETURNING x`.then((r2) => {
        check("returning", r2[0].x === 99);
        return sql`DELETE FROM ff_smoke WHERE x = ${99}`;
    });
}).then(() => {
    return Promise.all([
        sql`SELECT 1 AS a`,
        sql`SELECT 2 AS b`,
        sql`SELECT 3 AS c`,
    ]);
}).then((results) => {
    check("concurrent 1", results[0][0].a === 1);
    check("concurrent 2", results[1][0].b === 2);
    check("concurrent 3", results[2][0].c === 3);
    return sql.unsafe("SELECT 1/0 AS bad").then(() => {
        check("error should reject", false);
    }, (err) => {
        check("error rejects", err instanceof Error);
        check("sqlstate", err.code === "22012");
    });
}).then(() => sql`SELECT 1 AS ok`).then((rows) => {
    check("recovers after error", rows[0].ok === 1);
    sql.close();
    done("sql");
}).catch((err) => {
    console.log("FAIL: exception", err);
    try { sql.close(); } catch (e) {}
    done("sql");
});
