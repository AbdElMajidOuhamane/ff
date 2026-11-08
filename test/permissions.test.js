import { check, done } from "./lib.mjs";

const decoder = new TextDecoder();

function decode(v) {
  return v ? decoder.decode(v) : "";
}

// console.log writes to stderr in Fairyfly, so read both streams.
async function run(code, flags = []) {
  const c = child_process.spawn(process.argv[0], ["-e", code, ...flags]);
  const st = await c.wait();
  return { code: st.code, out: decode(c.stdout) + decode(c.stderr) };
}

function denied(r, needle) {
  return r.code !== 0 && r.out.includes(needle);
}

const base = "/tmp/ff-perm-" + process.pid;
const secret = base + "-secret.txt";
const outside = base + "-outside";
const dbPath = base + "/db.sqlite";

fs.mkdir(base, true);
fs.writeFile(secret, "secret");

// Parent-side redirect fixture: /redir sends the child to a port that is
// outside its --allow-net scope.
const PORTS = [39891, 39892, 39893];
let redirectPort = 0;
for (const p of PORTS) {
  try {
    http.serve({ port: p }, (url) => {
      if (url.startsWith("/redir")) {
        return new Response("", {
          status: 302,
          headers: { location: "http://127.0.0.1:1/" },
        });
      }
      return new Response("ok");
    });
    redirectPort = p;
    break;
  } catch (e) {}
}
if (redirectPort === 0) throw new Error("permissions: could not bind redirect port");

try {
  fs.writeFile(base + "/inside.txt", "hello");

  // ── fs read ──────────────────────────────────────────────────────
  let r = await run(`console.log(fs.readFile(${JSON.stringify(base + "/inside.txt")}))`);
  check("fs.readFile denied by default", denied(r, "requires --allow-read"));

  r = await run(
    `console.log(fs.readFile(${JSON.stringify(base + "/inside.txt")}))`,
    ["--allow-read=" + base],
  );
  check("fs.readFile allowed in scope", r.code === 0 && r.out.includes("hello"));

  r = await run(
    `console.log(fs.readFile(${JSON.stringify(base + "/../etc/hosts")}))`,
    ["--allow-read=" + base],
  );
  check("fs.readFile blocks traversal", denied(r, "requires --allow-read"));

  // ── fs write ─────────────────────────────────────────────────────
  r = await run(`fs.writeFile(${JSON.stringify(base + "/x.txt")}, "x")`);
  check("fs.writeFile denied by default", denied(r, "requires --allow-write"));

  r = await run(
    `fs.writeFile(${JSON.stringify(base + "/x.txt")}, "x"); console.log("wrote")`,
    ["--allow-write=" + base],
  );
  check("fs.writeFile allowed in scope", r.code === 0 && r.out.includes("wrote"));

  // ── symlink escape ───────────────────────────────────────────────
  child_process.execSync("ln -sfn '" + secret + "' '" + base + "/link'");
  r = await run(
    `console.log(fs.readFile(${JSON.stringify(base + "/link")}))`,
    ["--allow-read=" + base],
  );
  check("fs.readFile blocks symlink escape", denied(r, "requires --allow-read"));

  child_process.execSync("ln -sfn '" + outside + "' '" + base + "/dangle'");
  r = await run(
    `fs.writeFile(${JSON.stringify(base + "/dangle")}, "x")`,
    ["--allow-write=" + base],
  );
  check("fs.writeFile blocks dangling symlink", denied(r, "requires --allow-write"));
  check("dangling symlink target not created", fs.exists(outside) === false);

  // ── async fs ─────────────────────────────────────────────────────
  r = await run(`fs.readFileAsync(${JSON.stringify(base + "/inside.txt")})`);
  check("fs.readFileAsync denied by default", denied(r, "requires --allow-read"));

  // Known runtime issue: a completed async fs job pins the event loop, so the
  // child must exit explicitly after observing the result.
  r = await run(
    `fs.readFileAsync(${JSON.stringify(base + "/inside.txt")})` +
    `.then(s => { console.log("ASYNC:" + s); process.exit(0); })`,
    ["--allow-read=" + base],
  );
  check("fs.readFileAsync allowed in scope", r.code === 0 && r.out.includes("ASYNC:hello"));

  // ── process.chdir ────────────────────────────────────────────────
  r = await run(`process.chdir("/tmp")`);
  check("process.chdir denied by default", denied(r, "requires --allow-read"));

  r = await run(
    `process.chdir(${JSON.stringify(base)}); console.log(fs.readFile("inside.txt"))`,
    ["--allow-read=" + base],
  );
  check("process.chdir allowed and relative fs works", r.code === 0 && r.out.includes("hello"));

  // ── env filtering ────────────────────────────────────────────────
  r = await run(`console.log(process.env.HOME === undefined ? "hidden" : "visible")`, ["--allow-env=PATH"]);
  check("process.env hides denied names", r.code === 0 && r.out.includes("hidden"));

  r = await run(`console.log(process.env.PATH ? "visible" : "hidden")`, ["--allow-env=PATH"]);
  check("process.env exposes allowed names", r.code === 0 && r.out.includes("visible"));

  // ── net ──────────────────────────────────────────────────────────
  r = await run(`fetch("http://127.0.0.1:1/")`);
  check("fetch denied by default", denied(r, "requires --allow-net"));

  r = await run(`new WebSocket("ws://127.0.0.1:1/")`);
  check("WebSocket denied by default", denied(r, "requires --allow-net"));

  r = await run(`http.serve({ port: 0 }, () => {})`);
  check("http.serve denied by default", denied(r, "requires --allow-net"));

  r = await run(
    `fetch("http://127.0.0.1:${redirectPort}/ok").then(r => r.text()).then(t => console.log("NET:" + t))`,
    ["--allow-net=127.0.0.1:" + redirectPort],
  );
  check("fetch allowed by scoped net", r.code === 0 && r.out.includes("NET:ok"));

  r = await run(
    `fetch("http://127.0.0.1:${redirectPort}/redir")` +
    `.then(r => r.text())` +
    `.then(t => console.log("REDIR:" + t))` +
    `.catch(e => console.log("ERR:" + e))`,
    ["--allow-net=127.0.0.1:" + redirectPort],
  );
  check("fetch re-checks redirect target", r.out.includes("ERR:") && r.out.includes("allow-net"));
  check("fetch did not follow disallowed redirect", !r.out.includes("REDIR:"));

  // ── child_process ────────────────────────────────────────────────
  r = await run(`child_process.spawn("/bin/echo", ["x"])`);
  check("child_process denied by default", denied(r, "requires --allow-run"));

  r = await run(
    `child_process.spawn("/bin/echo", ["x"]).wait().then(() => console.log("ok"))`,
    ["--allow-run=/bin/echo"],
  );
  check("child_process allowed by scoped run", r.code === 0 && r.out.includes("ok"));

  r = await run(`child_process.execSync("echo x")`, ["--allow-run=/bin/echo"]);
  check("execSync still needs /bin/sh", denied(r, "requires --allow-run"));

  // ── ffi ──────────────────────────────────────────────────────────
  r = await run(`console.log(ffi.allowed)`);
  check("ffi.allowed false by default", r.code === 0 && r.out.includes("false"));

  r = await run(`console.log(ffi.allowed)`, ["--allow-ffi"]);
  check("ffi.allowed true with --allow-ffi", r.code === 0 && r.out.includes("true"));

  r = await run(
    `try { ffi.dlopen("x", {}); } catch (e) { console.log(e.name + " " + e.code); }`,
  );
  check(
    "ffi denial uses PermissionDenied",
    r.code === 0 && r.out.includes("PermissionDenied PERMISSION_DENIED"),
  );

  r = await run(`ffi.dlopen("x", {})`);
  check("ffi.dlopen denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.callback({ parameters: [], result: "void" }, () => {})`);
  check("ffi.callback denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.read(0n, "u8")`);
  check("ffi.read denies before dereference", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.write(0n, "u8", 1)`);
  check("ffi.write denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.copyBytes(0n, 1)`);
  check("ffi.copyBytes denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.writeBytes(0n, new Uint8Array(1))`);
  check("ffi.writeBytes denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.cstring(new TextEncoder().encode("hi\\0"))`);
  check("ffi.cstring denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.ptr(0n)`);
  check("ffi.ptr denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.view(0n)`);
  check("ffi.view denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.struct([["a", "i32"]])`);
  check("ffi.struct denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.union([["a", "i32"]])`);
  check("ffi.union denied by default", denied(r, "requires --allow-ffi"));

  r = await run(`ffi.isNull(null)`);
  check("ffi.isNull denied by default", denied(r, "requires --allow-ffi"));

  r = await run(
    `const b = new Uint8Array(1); console.log(ffi.ptr(b).addr > 0n)`,
    ["--allow-ffi"],
  );
  check("ffi raw helpers allowed with --allow-ffi", r.code === 0 && r.out.includes("true"));

  // ── sqlite ───────────────────────────────────────────────────────
  r = await run(`Database.open(${JSON.stringify(dbPath)})`);
  check("Database.open denied by default", denied(r, "requires --allow-read"));

  r = await run(
    `const db = Database.open(${JSON.stringify(dbPath)});` +
    `db.execNoArgs("CREATE TABLE t(x)"); db.close(); console.log("opened")`,
    ["--allow-read=" + base, "--allow-write=" + base],
  );
  check("Database.open allowed in scope", r.code === 0 && r.out.includes("opened"));
} finally {
  fs.rm(base, true);
  fs.rm(secret);
  fs.rm(outside);
}

done("permissions");
