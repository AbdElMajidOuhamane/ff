// Test 1: Basic setTimeout
console.log("1: Before setTimeout");

setTimeout(() => {
    console.log("2: Inside setTimeout");
}, 0);

console.log("3: After setTimeout");

// Test 2: setTimeout with delay
setTimeout(() => {
    console.log("4: Delayed 100ms");
}, 100);

// Test 3: Multiple timeouts - order matters
setTimeout(() => {
    console.log("5: First timeout");
}, 0);

setTimeout(() => {
    console.log("6: Second timeout");
}, 0);

// Test 4: Nested setTimeout
setTimeout(() => {
    console.log("7: Outer timeout");
    setTimeout(() => {
        console.log("8: Inner timeout");
    }, 0);
}, 0);

// Test 5: Promise vs setTimeout (microtask vs macrotask)
Promise.resolve().then(() => {
    console.log("9: Promise (microtask)");
});

setTimeout(() => {
    console.log("10: setTimeout (macrotask)");
}, 0);

console.log("11: End of script");
