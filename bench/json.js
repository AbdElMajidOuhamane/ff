var data = { arr: [] };
for (var i = 0; i < 1000; i++) {
    data.arr.push(i);
}
for (var i = 0; i < 1000; i++) {
    var json = JSON.stringify(data);
    var parsed = JSON.parse(json);
}
console.log("RESULT=" + parsed.arr.length);
