const base = "http://127.0.0.1:3000";
const j = (r) => r.text();
const check = async (name, fn) => {
  try {
    const out = await fn();
    console.log(out.ok ? `${"✓"} ${name}` : `${"✗"} ${name} :: ${out.msg || JSON.stringify(out)}\n`);
    return out.ok;
  } catch (e) {
    console.log(`✗ ${name} :: threw ${e.message}`);
    return false;
  }
};
const pass = [];

pass.push(await check("GET /health", async () => {
  const r = await fetch(`${base}/health`);
  const b = await j(r);
  return { ok: r.status === 200 && b.ok === true, ...{ msg: b } };
}));
pass.push(await check("GET /echo?x=1", async () => {
  const r = await fetch(`${base}/echo?x=1`);
  const b = await j(r);
  return { ok: r.status === 200 && b.path === "/echo" };
}));
pass.push(await check("POST /mirror", async () => {
  const r = await fetch(`${base}/mirror`, { method: "POST", body: "hello" });
  const b = await j(r);
  return { ok: r.status === 200 && (b.body || "") === "hello" };
}));
pass.push(await check("POST /api/todos (create)", async () => {
  const r = await fetch(`${base}/api/todos`, { method: "POST", body: JSON.stringify({ text: "x" }) });
  return { ok: r.status === 201 };
}));
pass.push(await check("GET /api/todos", async () => {
  const r = await fetch(`${base}/api/todos`);
  const b = await j(r);
  return { ok: r.status === 200 && Array.isArray(b.todos) };
}));
pass.push(await check("DELETE unknown -> 404", async () => {
  const r = await fetch(`${base}/api/todos/nope`, { method: "DELETE" });
  return { ok: r.status === 404 };
}));
pass.push(await check("/status/503", async () => {
  const r = await fetch(`${base}/status/503`);
  return { ok: r.status === 503 };
}));

const fails = pass.filter((x) => !x).length;
console.log(fails ? `\n${fails} FAILED` : "\nALL PASS");
process.exit(fails ? 1 : 0);
