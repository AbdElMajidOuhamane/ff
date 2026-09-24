import { check, done } from "./lib.mjs";

const dsn = process.env.PG_TEST_DSN;
if (!dsn) {
    console.log("[sql3] skip: PG_TEST_DSN not set");
    process.exit(0);
}

const sql = globalThis.sql;

// Callback-style sugar over native begin/commit/rollback (userland, 5 lines).
function transaction(fn) {
    return sql.begin().then((tx) => fn(tx).then(
        (r) => tx.commit().then(() => r),
        (e) => tx.rollback().then(() => { throw e; }),
    ));
}

sql`SELECT ${ { a: 1, b: "x", c: [1, 2] } } AS j`.then((rows) => {
    check("json param", rows[0].j.a === 1 && rows[0].j.b === "x" && rows[0].j.c[1] === 2);
    return sql`SELECT '{"z":true}'::json AS j, '[1,2]'::jsonb AS k`;
}).then((rows) => {
    check("json row", rows[0].j.z === true);
    check("jsonb row", Array.isArray(rows[0].k) && rows[0].k[0] === 1);
    return sql`SELECT 9007199254740993::int8 AS big, 42::int8 AS small`;
}).then((rows) => {
    check("bigint row", rows[0].big === 9007199254740993n);
    check("typeof bigint", typeof rows[0].big === "bigint");
    check("safe int stays number", rows[0].small === 42 && typeof rows[0].small === "number");
    return sql`SELECT ${9007199254740993n} AS n`;
}).then((rows) => {
    check("bigint param", rows[0].n === 9007199254740993n);
    return sql`SELECT ${[1, 2, 3]} AS a`;
}).then((rows) => {
    check("int array", JSON.stringify(rows[0].a) === "[1,2,3]");
    return sql`SELECT ${["x", "it's", 'q"q', null]} AS s`;
}).then((rows) => {
    check("text array", JSON.stringify(rows[0].s) === JSON.stringify(["x", "it's", 'q"q', null]));
    return sql`SELECT ${[true, false]} AS b`;
}).then((rows) => {
    check("bool array", JSON.stringify(rows[0].b) === "[true,false]");
    return sql`SELECT ${[[1, 2], [3, 4]]} AS m`;
}).then((rows) => {
    check("nested array", JSON.stringify(rows[0].m) === "[[1,2],[3,4]]");
    return sql`SELECT ARRAY[10,20]::int[] AS a, ARRAY['p','q']::text[] AS s`;
}).then((rows) => {
    check("int4 array row", JSON.stringify(rows[0].a) === "[10,20]");
    check("text array row", JSON.stringify(rows[0].s) === '["p","q"]');
    return sql.unsafe("DROP TABLE IF EXISTS ff_p3")
        .then(() => sql.unsafe("CREATE TABLE ff_p3 (id serial PRIMARY KEY, v int)"));
}).then(() => transaction((tx) => {
    return tx`INSERT INTO ff_p3(v) VALUES (${1})`
        .then(() => tx`SELECT count(*)::int AS n FROM ff_p3`)
        .then((r) => {
            check("tx sees own write", r[0].n === 1);
            return 7;
        });
})).then((r) => {
    check("tx helper returns", r === 7);
    return sql`SELECT count(*)::int AS n FROM ff_p3`;
}).then((rows) => {
    check("committed", rows[0].n === 1);
    return transaction((tx) => {
        return tx`INSERT INTO ff_p3(v) VALUES (${2})`.then(() => { throw new Error("boom"); });
    }).then(() => {
        check("rollback should reject", false);
    }, (err) => {
        check("rollback rejects", err instanceof Error && err.message === "boom");
    });
}).then(() => {
    return sql`SELECT count(*)::int AS n FROM ff_p3`;
}).then((rows) => {
    check("rolled back", rows[0].n === 1);
    return sql.begin();
}).then((tx) => {
    return tx`INSERT INTO ff_p3(v) VALUES (${3})`
        .then(() => tx.commit())
        .then(() => {
            try {
                return tx.commit().then(() => {
                    check("double commit rejects", false);
                }, () => {
                    check("double commit rejects", true);
                });
            } catch (e) {
                check("double commit rejects", e instanceof Error && /closed/.test(e.message));
            }
        })
        .then(() => {
            try {
                return tx`SELECT 1`.then(() => {
                    check("use after commit rejects", false);
                }, () => {
                    check("use after commit rejects", true);
                });
            } catch (e) {
                check("use after commit rejects", e instanceof Error && /closed/.test(e.message));
            }
        });
}).then(() => {
    return sql`SELECT count(*)::int AS n FROM ff_p3`;
}).then((rows) => {
    check("explicit commit", rows[0].n === 2);
    return sql.unsafe("DROP TABLE ff_p3");
}).then(() => {
    return sql`SELECT 1 AS ok`;
}).then((rows) => {
    check("recovers", rows[0].ok === 1);
    sql.close();
    done("sql3");
}).catch((err) => {
    console.log("FAIL: exception", err);
    try { sql.close(); } catch (e) {}
    done("sql3");
});
