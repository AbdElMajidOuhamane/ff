var o = { x: 1, y: 2, z: 3 };
var sum = 0;
for (var i = 0; i < 500000; i++) {
    sum += o.x + o.y + o.z;
}
console.log("RESULT=" + sum);
