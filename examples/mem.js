const ITERATIONS = 20;
const ROWS = 10_000_000;

const now =
    typeof performance !== "undefined" && performance.now
        ? () => performance.now()
        : () => Date.now();

for (let round = 1; round <= ITERATIONS; round++) {
    const start = now();

    let rows = new Array(ROWS);

    for (let i = 0; i < ROWS; i++) {
        rows[i] = {
            id: i,
            name: `user_${i}`,
            email: `user_${i}@example.com`,
            age: i % 100,
            score: (i * 2654435761) >>> 0,
            active: (i & 1) === 0,
            values: [
                i,
                i * 2,
                i * 3,
                Math.random(),
                Math.random(),
                Math.random()
            ],
            text: `Lorem ipsum dolor sit amet, consectetur adipiscing elit. ${i}`,
            meta: {
                city: `City_${i % 1000}`,
                country: `Country_${i % 100}`,
                zip: `${10000 + (i % 90000)}`
            }
        };
    }

    rows.reverse();

    rows.sort((a, b) => a.score - b.score);

    let sum = 0;

    for (const row of rows) {
        sum += row.values[2];
    }

    const json = JSON.stringify(rows);
    JSON.parse(json);

    // Drop references to force GC eventually
    rows = null;

    const elapsed = now() - start;

    console.log(
        `Round ${round}/${ITERATIONS} | ${elapsed.toFixed(2)} ms | checksum=${sum}`
    );
}
