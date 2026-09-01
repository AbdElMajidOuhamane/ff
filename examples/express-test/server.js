const express = require("express");
const app = express();
app.get("/", (req, res) => res.send("hello from express on fairyfly"));
app.get("/json", (req, res) => res.json({ ok: true, url: req.url, method: req.method }));
app.use((req, res) => res.status(404).send("not found: " + req.url));
app.listen(3000, () => console.log("up on 3000"));
