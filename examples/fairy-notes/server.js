// Fairy Notes — Express REST API.
"use strict";

const express = require("express");
const store = require("./store");

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/", (req, res) => {
    res.json({
        name: "Fairy Notes API",
        notes: store.count(),
        endpoints: [
            "GET /api/health",
            "GET /api/notes",
            "GET /api/notes/:id",
            "POST /api/notes",
            "PUT /api/notes/:id",
            "DELETE /api/notes/:id",
        ],
    });
});

app.get("/api/health", (req, res) => {
    res.json({ status: "ok", notes: store.count() });
});

app.get("/api/notes", (req, res) => {
    res.json({ notes: store.list() });
});

app.get("/api/notes/:id", (req, res) => {
    const note = store.get(req.params.id);
    if (!note) return res.status(404).json({ error: "note not found", id: req.params.id });
    res.json(note);
});

app.post("/api/notes", (req, res) => {
    const body = req.body || {};
    if (typeof body.title !== "string" || body.title.length === 0) {
        return res.status(400).json({ error: '"title" is required' });
    }
    const note = store.create(body.title, typeof body.body === "string" ? body.body : "");
    res.status(201).json(note);
});

app.put("/api/notes/:id", (req, res) => {
    const note = store.update(req.params.id, req.body || {});
    if (!note) return res.status(404).json({ error: "note not found", id: req.params.id });
    res.json(note);
});

app.delete("/api/notes/:id", (req, res) => {
    if (!store.remove(req.params.id)) {
        return res.status(404).json({ error: "note not found", id: req.params.id });
    }
    res.status(204).end();
});

app.use((req, res) => {
    res.status(404).json({ error: "not found", path: req.url });
});

// error middleware: body-parser parse failures -> 400, anything else -> 500
app.use((err, req, res, next) => {
    const status = err.statusCode || err.status || 500;
    res.status(status).json({ error: err.message || "internal error" });
});

const port = Number(process.env.PORT) || 3000;
app.listen(port, () => console.log("fairy-notes listening on port " + port));
