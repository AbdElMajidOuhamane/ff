# Fairyfly Runtime

A lightweight JavaScript runtime built with Zig and powered by V8 JavaScript engine.

---

## Vision

Fairyfly Runtime is designed to provide a modern, lightweight, and high-performance JavaScript runtime focused exclusively on backend development.

The project is built around a simple philosophy: modern backend development should be fast, predictable, and easy to understand. Instead of accumulating years of legacy behavior and unnecessary complexity, Fairyfly aims to offer a clean runtime with a small, maintainable codebase and a standards-first API.

The runtime is intended for developers who value performance, readability, and simplicity, while still having access to the modern Web APIs expected in today's JavaScript ecosystem.

---

## Design Principles

Fairyfly is built around a few core principles:

* Simplicity over complexity
* Modern Web APIs
* Fast startup time
* Low memory usage
* Clean architecture
* Easy-to-understand source code
* A pleasant developer experience

---

## Features

### Current
* V8 JavaScript engine
* ES Modules
* JavaScript file execution
* REPL (planned)

### Runtime APIs
* Console API
* Timers
* Fetch API
* File System API
* HTTP Server
* WebSocket
* URL API
* Streams
* Process API

---

## Project Structure

```text
src/
├── engine/     # V8 integration
├── runtime/    # Runtime initialization
├── api/        # Built-in JavaScript APIs
├── modules/    # ES Module loader
├── event/      # Event loop and timers
├── net/        # Networking
├── types/      # Shared runtime types
└── util/       # Internal utilities
#Note: This is just my personal project that im doing on my free time nothing serious (yet?).
