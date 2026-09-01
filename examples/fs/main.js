// Test 1: writeFile
fs.writeFile("test-output.txt", "Hello from Fairyfly!");
console.log("1. writeFile done");

// Test 2: exists
const exists1 = fs.exists("test-output.txt");
console.log("2. exists (should be true):", exists1);

// Test 3: readFile
const content = fs.readFile("test-output.txt", "utf8");
console.log("3. readFile (should be 'Hello from Fairyfly!'):", content);

// Test 4: mkdir
fs.mkdir("test-dir/sub/dir", true);
console.log("4. mkdir recursive done");

// Test 5: exists (directory)
const exists2 = fs.exists("test-dir/sub/dir");
console.log("5. dir exists (should be true):", exists2);

// Test 6: readdir
const entries = fs.readdir(".");
console.log("6. readdir:", entries);

// Test 7: rm (file)
fs.rm("test-output.txt");
const exists3 = fs.exists("test-output.txt");
console.log("7. rm file (should be false):", exists3);

// Test 8: rm (recursive)
fs.rm("test-dir", true);
const exists4 = fs.exists("test-dir");
console.log("8. rm recursive (should be false):", exists4);

console.log("All tests done!");
