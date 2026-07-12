var sum = 0;
for (var i = 0; i < 500; i++) {
    for (var j = 0; j < 500; j++) {
        sum += i * j;
    }
}
console.log("RESULT=" + sum);
