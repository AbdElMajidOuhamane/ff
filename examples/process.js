// process.argv
console.log("=== process.argv ===");
console.log("argv:", process.argv);
console.log("argv length:", process.argv.length);

// process.pid
console.log("\n=== process.pid ===");
console.log("pid:", process.pid);

// process.platform & arch
console.log("\n=== process.platform & arch ===");
console.log("platform:", process.platform);
console.log("arch:", process.arch);

// process.cwd() & chdir()
console.log("\n=== process.cwd & chdir ===");
console.log("cwd:", process.cwd());
process.chdir("/tmp");
console.log("after chdir:", process.cwd());
process.chdir("/");
console.log("after chdir back:", process.cwd());

// process.env
console.log("\n=== process.env ===");
console.log("HOME:", process.env.HOME);
console.log("PATH:", process.env.PATH);
console.log("USER:", process.env.USER);

// process.exit (uncomment to test — will exit immediately)
// process.exit(0);

console.log("\n=== All process tests passed! ===");
