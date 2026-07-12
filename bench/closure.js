function makeCounter() {
    var count = 0;
    return function() {
        count++;
        return count;
    };
}
var counter = makeCounter();
for (var i = 0; i < 200000; i++) {
    counter();
}
console.log("RESULT=" + counter());
