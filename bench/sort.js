var arr = [];
for (var i = 0; i < 100000; i++) {
    arr.push(Math.random() * 100000 | 0);
}
arr.sort(function(a, b) { return a - b; });
console.log("RESULT=" + arr.length);
