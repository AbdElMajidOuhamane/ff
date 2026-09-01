const N = 10;
const started = Date.now();
let count = 0;

(async () => {
    const statuses = await Promise.all(
        Array.from({ length: N }, async (_, i) => {
            const r = await fetch("https://example.com/");
            const body = await r.text();
            count += 1;
            console.log("[" + i + "] status=" + r.status + " bytes=" + body.length);
            return r.status;
        })
    );
    console.log("all: count=" + statuses.length + " statuses=" + statuses.join(",") +
        " ms=" + (Date.now() - started));
})();
