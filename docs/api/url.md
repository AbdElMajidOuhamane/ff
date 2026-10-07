---
title: URL
description: URL and URLSearchParams — parsing, mutation, base resolution, parse/canParse statics.
order: 12
---

# `URL`

A complete WHATWG-style URL implementation:

```js
const u = new URL("/a/b?x=1#frag", "https://h.example:8443");

u.href;       // "https://h.example:8443/a/b?x=1#frag"
u.origin;     // "https://h.example:8443"
u.protocol;   // "https:"
u.hostname;   // "h.example"
u.port;       // "8443"
u.pathname;   // "/a/b"
u.search;     // "?x=1"
u.hash;       // "#frag"
```

## `new URL(input, base?)`

| | |
|---|---|
| Signature | `(string, string?) → URL` |
| Throws | `TypeError: Invalid URL` (or `URL constructor requires at least 1 argument`) |

With a base, relative inputs resolve against it:

```js
new URL("api/users", "https://x.dev/v1/").href;   // "https://x.dev/v1/api/users"
new URL("//cdn.x.dev/a.js", "https://x.dev").href; // "https://cdn.x.dev/a.js"
```

### Properties

| Property | Settable | Description |
|---|---|---|
| `href` | yes | Full URL — setting re-parses everything |
| `origin` | **no** | Scheme + host + port |
| `protocol` | yes | Includes the `:` |
| `host` | yes | Hostname + port |
| `hostname` | yes | Host without port |
| `port` | yes | Empty string if default |
| `pathname` | yes | Path |
| `search` | yes | Includes leading `?` |
| `hash` | yes | Includes leading `#` |
| `username` | yes | Before `@` |
| `password` | yes | After `@` |
| `searchParams` | no | Read view of the query — reflects URL edits, but edits to it never flow back (see below) |

Setting a component updates the whole URL:

```js
const u = new URL("https://x.dev/a");
u.port = "8443";
u.href;   // "https://x.dev:8443/a"
```

### Methods

```js
const u = new URL("https://x.dev/a?b=1");
u.toString();   // "https://x.dev/a?b=1"   (same as href)
u.toJSON();     // "https://x.dev/a?b=1"
String(u);      // "https://x.dev/a?b=1"
```

### Statics

```js
URL.parse("not a url");          // null        — never throws
URL.parse("https://x.dev");      // URL instance
URL.parse("/rel", "https://x.dev"); // URL resolved against base
URL.canParse("https://x.dev");   // true
URL.canParse("not a url");       // false
```

| Static | Signature | Behaviour |
|---|---|---|
| `URL.parse(input, base?)` | `(string, string?) → URL \| null` | `null` instead of throwing |
| `URL.canParse(input, base?)` | `(string, string?) → boolean` | Quick validity check |

Prefer `URL.parse` when input is untrusted:

```js
const u = URL.parse(userInput, "https://default.invalid");
if (!u) return new Response("bad url", { status: 400 });
```

## `URLSearchParams`

Reached through `url.searchParams` or constructed directly:

```js
const sp = new URLSearchParams("a=1&b=2");
sp.append("a", "10");
sp.set("c", "3");
sp.get("a");          // "1"   (first match)
sp.getAll("a");       // ["1", "10"]
sp.has("b");          // true
sp.delete("b");
sp.toString();        // "a=1&a=10&c=3"   (insertion order, NOT percent-encoded)
sp.size();            // 3      ← a METHOD, not a property
```

### Methods

| Method | Signature | Notes |
|---|---|---|
| `get(name)` | `(string) → string \| null` | First value, verbatim (no percent-decoding) |
| `getAll(name)` | `(string) → string[]` | All values |
| `has(name)` | `(string) → boolean` | |
| `set(name, value)` | `(string, string)` | Replaces all matches |
| `append(name, value)` | `(string, string)` | |
| `delete(name)` | `(string) → void` | |
| `sort()` | `() → void` | Key order |
| `toString()` | `() → string` | `a=1&b=2` — verbatim, never percent-encoded |
| `size()` | `() → number` | **Call it** — it's a function |
| `entries()` / `keys()` / `values()` | `() → string[][]` / `string[]` / `string[]` | Return **arrays**, not iterators |
| `forEach(fn)` | `((value, key, parent) => void)` | |

### The view is one-way

Edits to the URL re-parse the params — but edits to the params never
touch the URL:

```js
const u = new URL("https://x.dev/?x=1");
u.search = "y=2";                    // re-parses …
u.searchParams.get("y");             // "2" — params followed the URL

u.searchParams.append("z", "3");     // …but not vice versa
u.href;                              // "https://x.dev/?y=2" — z is lost
```

## Patterns

### Build a query safely

Nothing here percent-encodes: `set()` stores values verbatim,
`toString()` emits them verbatim, and the URL parser percent-*decodes*
`%XX` on the way in (so a decoded `&` or `=` silently splits fields —
`%26` becomes a field separator, `%23` truncates at `#`). `encodeURIComponent`
exists — use it, and keep encoded text out of `new URL` / `.search`:

```js
const qs = "q=" + encodeURIComponent("café & tea") + "&page=2";
const res = await fetch("https://api.example.com/search?" + qs);
// wire query: q=caf%C3%A9%20%26%20tea&page=2 — intact
```

Two things that look right but aren't: `fetch(urlObject)` throws
`Invalid URL` — always pass a string (`fetch(u.href)`) — and
`u.searchParams.set(...)` followed by `fetch(u.href)` sends the *old*
query, because param edits never reach the URL.

### Parse a request URL

```js
http.serve({ port: 3000 }, (raw, method) => {
  const u = new URL(raw, "http://localhost");
  if (u.pathname === "/health") return Response.json({ ok: true });
  return Response.json({ path: u.pathname, page: u.searchParams.get("page") });
});
```

## Gotchas

- `searchParams.size` and `Headers.size` are **functions** — call them
  (`sp.size()`), they are not numeric properties.
- Query values are never percent-encoded on output — but the URL parser
  *decodes* `%XX` on input. Encode with `encodeURIComponent` and keep
  encoded strings out of `new URL` / `.search`.
- `fetch()` takes a URL *string*, not a `URL` object (`fetch(u)` throws
  `Invalid URL` — use `fetch(u.href)`).
- `for...of` doesn't work on `URLSearchParams` (or `Headers`) — loop over
  `.entries()` instead.
- `URL.parse` returns `null`; the **constructor throws**. Pick per context.
- Input longer than the internal buffer falls back to heap allocation —
  there is no documented length cap, but absurd URLs are waste.
- `origin` is read-only; use `href = …` to change the host.
- No `URL.canParse` in very old environments — it exists here.

## See also

- [`fetch`](/docs/api/fetch) — passing URLs to `fetch`
- [Request / Response](/docs/api/request-response)
- [Compatibility](/docs/reference/compatibility)
