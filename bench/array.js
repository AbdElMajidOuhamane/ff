var arr = [];
for (var i = 0; i < 10000; i++) {
    arr.push(i);
}
var result = arr
    .map(function(x) { return x * 2; })
    .filter(function(x) { return x % 3 === 0; })
    .reduce(function(sum, x) { return sum + x; }, 0);
console.log("RESULT=" + result);
