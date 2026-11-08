    <div align="center">
      <img src="assets/ff.webp" alt="Fairyfly logo" width="110" />
      <h1>Fairyfly Runtime (<code>ff</code>)</h1>
      <p>
        <strong>A fast, low-memory, backend-focused JavaScript runtime built in Zig and powered by QuickJS.</strong>
      </p>
      <p>
        <a href="https://github.com/AbdElMajidOuhamane/ff/actions/workflows/ci.yml"><img src="https://github.com/AbdElMajidOuhamane/ff/actions/workflows/ci.yml/badge.svg"
        alt="CI" /></a>
        <a href="https://github.com/AbdElMajidOuhamane/ff/releases/latest"><img src="https://img.shields.io/github/v/release/AbdElMajidOuhamane/ff" alt="Release" /></a>
        <a href="LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-blue.svg" alt="License: MPL-2.0" /></a>
      </p>
      <p>
        <a href="docs/getting-started/introduction.md">Getting Started</a> ·
        <a href="docs/api/overview.md">API Reference</a> ·
        <a href="docs/concepts/permissions.md">Permissions</a> ·
        <a href="docs/reference/cli.md">CLI Reference</a> ·
        <a href="#performance">Benchmarks</a>
      </p>
    </div>



    ## Highlights

    - **Tiny Footprint & Instant Startup**: ~5–10 MB RSS under load—built for containers, edge workloads, CLI tools, and dense multi-tenant servers (~100 instances per GB).
    - **Deny-by-Default Security**: Capability-based native permissions (`--allow-net`, `--allow-read`, `--allow-write`, `--allow-env`, `--allow-run`, `--allow-ffi`).
    - **Batteries-Included Backend APIs**: Native HTTP/1.1 & HTTP/2 server, WebSocket client & server, SQLite (`Database`), PostgreSQL with TLS (`sql`), WebCrypto + async
    native `bcrypt`, Workers, and FFI.
    - **Auditable Codebase**: ~32k lines of readable Zig across ~75 files on top of `libxev` (`io_uring`, `epoll`, `kqueue`), `QuickJS`, `BearSSL`, `SQLite`, and `nghttp2`.

    ---

    ## Installation

    ### macOS & Linux (Prebuilt Binary)

    ```sh
    curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh

  Detects your OS/architecture (x86_64 or aarch64), verifies the SHA-256 checksum, and installs ff to ~/.local/bin/ff. Update anytime with:

    ff upgrade

  ### Docker

    docker pull ghcr.io/abdelmajidouhamane/ff:latest
    docker run --rm ghcr.io/abdelmajidouhamane/ff:latest ff --version
  ──────
  ## Quick Start

    # Run inline JavaScript
    ff -e 'console.log("Hello from Fairyfly!")'

    # Scaffold and run a project
    ff init -y my-app
    cd my-app
    ff start

  ### 1. HTTP Server (http.serve)

    // server.js
    const server = http.serve({ port: 3000 }, (url, method, body, headers) => {
      if (url === "/health") {
        return Response.json({ ok: true, ua: headers.get("user-agent") });
      }
      if (url === "/echo" && method === "POST") {
        return new Response(body, { status: 200 });
      }
      return new Response("Not Found", { status: 404 });
    });

    process.once("SIGTERM", () => server.close());

    ff server.js --allow-net=0.0.0.0:3000

  ### 2. Outbound HTTP (fetch + AbortSignal)

    // client.js
    const res = await fetch("https://api.example.com/items", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "notebook" }),
      signal: AbortSignal.timeout(5000),
    });
    console.log(res.status, await res.json());

    ff client.js --allow-net=api.example.com:443

  ### 3. Databases (Database SQLite & sql Postgres)

    // sqlite.js
    const db = Database.open("app.db");
    db.execNoArgs("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT)");
    db.exec("INSERT INTO notes (text) VALUES (?)", ["Ship v0.3"]);
    console.log(db.rows("SELECT * FROM notes"));
    db.close();

    ff sqlite.js --allow-read=app.db --allow-write=.
  ──────
  ## Security & Permissions

  All native I/O is deny-by-default and controlled strictly via CLI flags. Denied operations throw PermissionDenied (err.code === "PERMISSION_DENIED").

   Flag                                                 │ Grants Access To                                             │ Scope Format
  ──────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────
   --allow-net                                          │ fetch, http.serve, WebSocket, udp, Postgres sql              │ host, host:port, *.domain
   --allow-read                                         │ fs reads, process.chdir, runtime TLS cert/CA files           │ Paths (resolved from launch cwd)
   --allow-write                                        │ fs writes, SQLite database file + parent directory           │ Paths
   --allow-env                                          │ process.env, DATABASE_URL / PG* variables                    │ Exact variable names
   --allow-run                                          │ child_process (spawn, exec, execSync), external process.kill │ Binary names or absolute paths
   --allow-ffi                                          │ ffi native libraries and raw memory helpers                  │ Bare flag only
   --allow-all                                          │ Full access to all categories above                          │ Bare flag only

  │ Full details: Permissions Guide /docs/concepts/permissions.md
  ──────
  ## Built-in APIs Overview

   Global / API                  │ Description
  ───────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   http.serve                    │ High-performance HTTP/1.1, HTTP/2, TLS, & WebSocket server ((url, method, body, headers) handler, graceful server.close()).
   fetch                         │ Async HTTP/1.1 client (16 concurrent workers, TLS, AbortSignal, redirect credential stripping).
   Request / Response / Headers  │ Web-standard HTTP primitives (Response.json(), pooled Headers, Blob, FormData).
   WebSocket                     │ Native client & server WebSockets (send, sendBinary, close, RFC 6455 masking & UTF-8 validation).
   Database                      │ Embedded synchronous SQLite 3 (open, exec, execNoArgs, rows, prepare).
   sql / SQL                     │ Pooled async PostgreSQL client with tagged templates, transactions, and BearSSL sslmode=verify-full.
   crypto                        │ randomUUID(), getRandomValues(), subtle (digest, HMAC sign/verify/importKey/exportKey), and async worker-pooled crypto.bcrypt (hash,
                                 │ verify).
   AbortController / AbortSignal │ Standard cancellation with AbortSignal.timeout(ms) and throwIfAborted().
   structuredClone               │ Deep cloning with cycle support for Map, Set, Date, TypedArray, Error (up to 4 MB).
   Worker                        │ Multi-threaded JS workers (up to 8 OS threads) with structured-clone postMessage.
   fs                            │ Synchronous and Promise-based (*Async) filesystem operations.
   process / child_process       │ env, argv, POSIX signals (on/once/off/kill), stats(), memoryUsage(), and subprocess execution.
   udp / ffi                     │ Native UDP sockets and C Foreign Function Interface (dlopen, callback, structs/pointers).

  │ Full signatures and edge cases: API Reference /docs/api/overview.md · Limitations /docs/reference/limitations.md
  ──────
  ## Performance

  ### macOS (Apple Silicon, kqueue)

  wrk -t8 -c100 -d10s on the same keep-alive hello-world handler:

   Runtime                          │                          Req/sec │                    Latency (p50) │                   Latency (p99) │                        Peak RSS
  ──────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────┼─────────────────────────────────┼─────────────────────────────────
   Fairyfly                         │                          138,000 │                          0.66 ms │                         0.85 ms │                            5 MB
   Deno 2.9                         │                          110,000 │                          0.86 ms │                         1.00 ms │                           48 MB
   Bun 1.4                          │                          107,000 │                          0.87 ms │                         1.71 ms │                           34 MB
   Node 23                          │                           69,000 │                          1.36 ms │                         1.69 ms │                           82 MB

  ### Linux (aarch64, io_uring vs epoll)

  wrk -t4 -c100 -d10s (3-run medians, static musl ReleaseFast):

   Runtime                                   │                         Req/s (io_uring) │                            Req/s (epoll) │              Peak RSS (io_uring / epoll)
  ───────────────────────────────────────────┼──────────────────────────────────────────┼──────────────────────────────────────────┼──────────────────────────────────────────
   Fairyfly                                  │                                  309,000 │                                  171,000 │                            10 MB / 16 MB
   Deno 2.9.7                                │                                  248,000 │                                  247,000 │                            44 MB / 44 MB
   Bun 1.4.2                                 │                                  187,000 │                                  184,000 │                            34 MB / 35 MB
   Node 18                                   │                                   55,000 │                                   57,000 │                            88 MB / 88 MB
  ──────
  ## CLI Reference

   Command                                                                              │ Description
  ──────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────
   ff <file.js> [--allow-*]                                                             │ Execute a JavaScript or bytecode (.ffbc) file
   ff -e "<code>" [--allow-*]                                                           │ Evaluate inline JavaScript
   ff start [--allow-*]                                                                 │ Run the "main" entry point from ff.json
   ff --watch <file|start> ...                                                          │ Watch project files and restart on changes
   ff test [filter] [--allow-*]                                                         │ Run test/*.test.js suites
   ff init [-y] [<dir>]                                                                 │ Initialize a new project (ff.json)
   ff imprint <pkg...>                                                                  │ Install pure-JS ESM packages from npm, GitHub, Codeberg, or .tar.gz
   ff sever <pkg...>                                                                    │ Remove dependencies and prune unused packages
   ff compile <in.js> [-o out.ffbc]                                                     │ Compile JS into standalone QuickJS bytecode
   ff fmt [--write|--check] <files>                                                     │ Format code via Prettier
   ff repl                                                                              │ Start an interactive REPL
   ff upgrade [--check]                                                                 │ Self-update ff with SHA-256 verification
  ──────
  ## Building from Source

  Requires Zig 0.16.0 on macOS or Linux.

    # 1. Fetch and verify vendored C dependencies (QuickJS, BearSSL, SQLite, nghttp2)
    ./scripts/fetch-vendors.sh

    # 2. Build ReleaseFast binary and install to ~/.local/bin/ff
    make install

    # 3. Run unit + integration test suites
    make test
  Build Flags & Architecture Details
    zig build -Doptimize=ReleaseFast   # Default production build
    zig build -Dio_uring=false         # Linux: use epoll instead of io_uring
    zig build -Dbearssl=false          # Disable TLS support
    zig build -Dffi=false              # Disable libffi dynamic loading
    zig build -Dsanitize-c=true        # Enable C UBSan for debugging
    make ci                            # Run fmt + build + Zig/JS tests + fuzz smoke

  See Architecture /docs/concepts/architecture.md and Limitations /docs/reference/limitations.md for connection table sizing, memory caps, and Node/browser differences.
  ──────
  ## Documentation

  Complete documentation is available in docs/ /docs/index.md:

  • Getting Started: Introduction /docs/getting-started/introduction.md · Installation /docs/getting-started/installation.md · Quickstart /docs/getting-started/quickstart.md
  • Core Concepts: Permissions /docs/concepts/permissions.md · Event Loop /docs/concepts/event-loop.md · Concurrency /docs/concepts/concurrency.md · Errors
  /docs/concepts/errors.md · Architecture /docs/concepts/architecture.md
  • Guides: HTTP Server /docs/guides/http-server.md · HTTP/2 /docs/guides/http2.md · TLS /docs/guides/tls.md · Fetch Client /docs/guides/fetch-client.md · WebSocket
  /docs/guides/websocket.md · Workers /docs/guides/workers.md · Packages /docs/guides/packages.md · Testing /docs/guides/testing.md · Deploy /docs/guides/deploy.md
  • Reference: API Overview /docs/api/overview.md · CLI /docs/reference/cli.md · Compatibility /docs/reference/compatibility.md · Limitations /docs/reference/limitations.md
  ──────
  ## License

  Licensed under the Mozilla Public License 2.0 (MPL-2.0) /LICENSE.
