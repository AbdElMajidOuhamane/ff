// Fairy Notes store — JSON file persistence, write-through on every mutation.
"use strict";

const fs = require("fs");
const path = require("path");

const DATA_DIR = path.join(__dirname, "data");
const DATA_FILE = path.join(DATA_DIR, "notes.json");

const state = { nextId: 1, notes: {} };

function load() {
    try {
        if (fs.existsSync(DATA_FILE)) {
            const parsed = JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
            if (parsed && typeof parsed === "object") {
                state.nextId = parsed.nextId || 1;
                state.notes = parsed.notes || {};
            }
        }
    } catch (_) {
        // corrupt/missing data file: start fresh (keeps runs deterministic)
        state.nextId = 1;
        state.notes = {};
    }
}

function save() {
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, true);
    fs.writeFileSync(DATA_FILE, JSON.stringify(state, null, 2));
}

function list() {
    return Object.keys(state.notes)
        .map(Number)
        .sort((a, b) => a - b)
        .map((id) => state.notes[id]);
}

function get(id) {
    return state.notes[String(id)] || null;
}

function create(title, body) {
    const id = String(state.nextId++);
    const note = { id, title, body: body || "" };
    state.notes[id] = note;
    save();
    return note;
}

function update(id, patch) {
    const note = state.notes[String(id)];
    if (!note) return null;
    if (patch.title !== undefined) note.title = patch.title;
    if (patch.body !== undefined) note.body = patch.body;
    save();
    return note;
}

function remove(id) {
    if (!state.notes[String(id)]) return false;
    delete state.notes[String(id)];
    save();
    return true;
}

function count() {
    return Object.keys(state.notes).length;
}

load();

module.exports = { list, get, create, update, remove, count };
