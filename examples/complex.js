
function fibonacci(n, memo = {}) {
    if (n in memo) return memo[n];
    if (n <= 1) return n;
    memo[n] = fibonacci(n - 1, memo) + fibonacci(n - 2, memo);
    return memo[n];
}
// classes
class Vector {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
    add(other) {
        return new Vector(this.x + other.x, this.y + other.y);
    }
    magnitude() {
        return Math.sqrt(this.x ** 2 + this.y ** 2);
    }
    toString() {
        return `Vector(${this.x}, ${this.y})`;
    }
}
// generators
function* range(start, end, step = 1) {
    for (let i = start; i < end; i += step) {
        yield i;
    }
}
// promises (synchronous since no event loop)
const result = Promise.resolve(42);
// async/await (synchronous since no event loop)
async function compute() {
    const val = await Promise.resolve("async works!");
    return val;
}
// destructuring, spread, rest
const [a, b, ...rest] = [1, 2, 3, 4, 5];
const merged = { x: 1, ...{ y: 2, z: 3 } };
// map, filter, reduce
const nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const processed = nums
    .filter(n => n % 2 === 0)
    .map(n => n ** 2)
    .reduce((sum, n) => sum + n, 0);
// regex
const email = "user@example.com";
const valid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
// JSON
const data = { users: [{ name: "Majid", age: 30 }, { name: "Ali", age: 25 }] };
const json = JSON.stringify(data, null, 2);
const parsed = JSON.parse(json);
// Output
console.log("=== Fibonacci ===");
for (const i of range(0, 15)) {
    console.log(`fib(${i}) = ${fibonacci(i)}`);
}
console.log("\n=== Vectors ===");
const v1 = new Vector(3, 4);
const v2 = new Vector(1, 2);
const v3 = v1.add(v2);
console.log(`${v1} + ${v2} = ${v3}`);
console.log(`magnitude: ${v3.magnitude()}`);
console.log("\n=== Array Processing ===");
console.log(`even squares sum: ${processed}`);
console.log("\n=== Destructuring ===");
console.log(`a=${a}, b=${b}, rest=${rest}`);
console.log(`merged: ${JSON.stringify(merged)}`);
console.log("\n=== Async ===");
compute().then(console.log);
console.log("\n=== Regex ===");
console.log(`${email} valid: ${valid}`);
console.log("\n=== JSON ===");
console.log(json);
