---
title: URL
description: URL and URLSearchParams — parsing, mutation, base resolution, parse/canParse statics.
order: 12
---

# `URL`

A WHATWG-style `URL` available as a global. It handles the common cases well but deviates from the spec in several places — the important ones are called out inline and summarised in [Gotchas](#gotchas).

```js
const u = new URL("/a/b?x=1#frag", "https://h.example:8443");

u.href;       // "https://h.example:8443/a/b?x=1#frag"
u.origin;     // "https://h.example:8443"
u.protocol;   // "https:"
u.host;       // "h.example:8443"
u.hostname;   // "h.example"
u.port;       // "8443"
u.pathname;   // "/a/b"
u.search;     // "?x=1"
u.hash;       // "#frag"
u.username;   // ""
u.password;   // ""
```

## `new URL(input, base?)`

| | |
|---|---|
| Signature | `(input: string, base?: string) → URL` |
| Throws | `TypeError` (see below) |

`input` is stringified with `ToString`, so another `URL` works as input (`new URL(otherUrl)` reuses its `href`). Calling the constructor **without `new`** throws `TypeError: must be called with new`.

All constructor failures are `TypeError`:

| Call | `message` |
|---|---|
| `new URL()` | `"URL constructor requires at least 1 argument"` |
| `new URL("not a url")` | `"Invalid URL"` |
| `new URL("example.com")` (no scheme, no base) | `"Invalid URL"` |
| `new URL("/rel")` (relative, no base) | `"Invalid URL"` |

A `base`, if given, must itself be absolute.

### Relative resolution

With a base, relative inputs resolve against it:

```js
new URL("api/users", "https://x.dev/v1/").href;    // "https://x.dev/v1/api/users"
new URL("/root", "https://x.dev/v1/a").href;       // "https://x.dev/root"
new URL("../up", "https://x.dev/v1/a/b").href;     // "https://x.dev/v1/up"
new URL("?q=1", "https://x.dev/v1/p").href;        // "https://x.dev/v1/p?q=1"
new URL("#f", "https://x.dev/v1/p").href;          // "https://x.dev/v1/p#f"
new URL("", "https://x.dev/v1/p?q=1#f").href;      // "https://x.dev/v1/p?q=1"
new URL("https://other/x", "https://x.dev/").href; // "https://other/x"
```

> **Protocol-relative URLs are not supported.** An input beginning with `//` is treated as a root-relative path, so the base host is kept and the result gains a doubled slash:
>
> ```js
> new URL("//cdn.x.dev/a.js", "https://x.dev").href;
> // "https://x.dev//cdn.x.dev/a.js"   — NOT "https://cdn.x.dev/a.js"
> ```
>
> Pass an absolute URL when you need a different host.

### Properties

Every property below is an accessor on the prototype.

| Property | Settable | Notes |
|---|---|---|
| `href` | yes | Full serialization; assigning re-parses the whole URL |
| `origin` | **no** | Scheme + host + port, or `"null"` for `file:` and non-special schemes |
| `protocol` | yes | Includes the `:` (the setter accepts it with or without) |
| `host` | yes | Hostname + port; setting a host without a port clears the port |
| `hostname` | yes | Host only; the existing port is kept |
| `port` | yes | `""` when it is the scheme's default; setting the default clears it |
| `pathname` | yes | A leading `/` is added if missing |
| `search` | yes | Leading `?` optional on input and present in the value; `""` removes the query |
| `hash` | yes | Leading `#` optional on input and present in the value; `""` removes it |
| `username` | yes | Before `@` |
| `password` | yes | After `:` in the userinfo |
| `searchParams` | no | A `URLSearchParams` view that follows URL edits one-way (see below) |

```js
const u = new URL("https://x.dev:8443/a");
u.port = "443";       // https's default → removed
u.href;               // "https://x.dev/a"

u.host = "y.dev";     // no port in the value → port dropped
u.href;               // "https://y.dev/a"

u.hostname = "z.dev"; // port preserved
u.href;               // "https://z.dev/a"
```

Setter rules to know:

- **Invalid values are silently ignored.** `u.href = "::bad::"` leaves the URL unchanged — no throw.
- **Values longer than 8192 bytes are silently ignored** (setters copy through a fixed 8 KiB buffer). The constructor has no such limit; long `input` strings fall back to heap allocation.
- `origin` has **no setter**: assigning it is a silent no-op in a classic script and a `TypeError` (`"no setter for property"`) in strict mode / ESM. Change the host via `href = …`.
- `searchParams` is a plain data property, and the object it returns is the same one kept in sync when a URL setter re-parses the URL.

### Methods

```js
const u = new URL("https://x.dev/a?b=1");
u.toString();   // "https://x.dev/a?b=1"   (same as href)
u.toJSON();     // "https://x.dev/a?b=1"
String(u);      // "https://x.dev/a?b=1"
JSON.stringify(u); // produces the quoted string "https://x.dev/a?b=1"
```

### Statics

```js
URL.parse("not a url");             // null
URL.parse("https://x.dev");         // URL instance
URL.parse("/rel", "https://x.dev"); // URL resolved against base
URL.parse();                        // null

URL.canParse("https://x.dev");      // true
URL.canParse("not a url");          // false
URL.canParse();                     // false
```

| Static | Signature | Behaviour |
|---|---|---|
| `URL.parse(input, base?)` | `(string, string?) → URL \| null` | `null` instead of throwing |
| `URL.canParse(input, base?)` | `(string, string?) → boolean` | Validity check |

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
sp.get("a");          // "1"    (first match)
sp.getAll("a");       // ["1", "10"]
sp.has("b");          // true
sp.has("b", "2");     // true   (optional value)
sp.delete("b");
sp.toString();        // "a=1&c=3&a=10"
sp.size();            // 3      ← a METHOD, not a property
```

Only a string argument is parsed. `new URLSearchParams()` — or any non-string argument, including an object — produces an **empty** set; there is no iterable/pair initialization.

Parsing is minimal: split on `&`, split each pair on the **first** `=`, and store both sides verbatim. Consequences:

- no percent-decoding and no `+` → space (`"a=1+2"` → `"1+2"`, `"a=%20"` → `"%20"`);
- a bare name gets the value `""` (`"flag"` → `get("flag") === ""`);
- a leading `?` is not stripped (`"?a=1"` → name `"?a"`, not `"a"`).

### Methods

| Method | Signature | Notes |
|---|---|---|
| `get(name)` | `(string) → string \| null` | First value, verbatim |
| `getAll(name)` | `(string) → string[]` | All values (`[]` if none) |
| `has(name[, value])` | `(string, string?) → boolean` | Optional value match |
| `set(name, value)` | `(string, string)` | Replaces every match with a single pair |
| `append(name, value)` | `(string, string)` | Adds a pair; duplicates allowed |
| `delete(name[, value])` | `(string, string?) → void` | Removes matching pairs |
| `sort()` | `() → void` | Sorts by name (ascending) |
| `toString()` | `() → string` | `a=1&b=2` — verbatim, never encoded |
| `size()` | `() → number` | **Call it** — it is a function |
| `entries()` | `() → string[][]` | `[[name, value], …]` — an **array**, not an iterator |
| `keys()` | `() → string[]` | Array |
| `values()` | `() → string[]` | Array |
| `forEach(fn)` | `((value, name, params) => void)` | Iterates in order |

Two ordering facts:

- `delete` uses a **swap-remove**: the last entry moves into the deleted slot, so `toString()` order can change after a deletion.

  ```js
  const sp = new URLSearchParams("a=1&b=2&c=3");
  sp.delete("a");
  sp.toString(); // "c=3&b=2"  — the last pair moved into the first slot
  ```

- There is **no `Symbol.iterator`**, so `for...of`, spread, and destructuring do not work directly on a `URLSearchParams`. Iterate `.entries()` instead:

  ```js
  for (const [name, value] of new URLSearchParams("a=1&b=2").entries()) {
    console.log(name, value);
  }
  ```

### Percent-encoding is never applied on output

`toString()` emits names and values exactly as stored. Encode on the way in with `encodeURIComponent`:

```js
const sp = new URLSearchParams();
sp.set("q", "café & tea");
sp.toString(); // "q=café & tea"   ← raw space and & are emitted as-is
```

Build the query string manually rather than round-tripping through a URL:

```js
(async () => {
  const qs = "q=" + encodeURIComponent("café & tea") + "&page=2";
  const res = await fetch("https://api.example.com/search?" + qs);
  // wire query: q=caf%C3%A9%20%26%20tea&page=2 — intact
})();
```

### The URL parser decodes `%XX`; `URLSearchParams` does not

These two look alike but behave differently:

```js
new URLSearchParams("q=caf%C3%A9").get("q");                 // "caf%C3%A9"  (untouched)
new URL("https://x.dev/?q=caf%C3%A9").searchParams.get("q"); // "café"       (decoded)
```

When a query comes from a `URL`, the parser percent-decodes it **before** the parameters are split, so a decoded separator splits fields and a decoded `#` lands inside the query:

```js
const u = new URL("https://x.dev/?a=%26b"); // %26 → "&"
u.searchParams.get("a");                    // ""   (the & split "a=" and "b")
u.searchParams.get("b");                    // ""

new URL("https://x.dev/?a=%23b").href;      // "https://x.dev/?a=#b"  (literal #)
new URL("https://x.dev/?a=%23b").hash;      // ""   — not treated as a fragment
```

Keep encoded text out of `new URL(...)` and `.search`.

### The view is one-way

URL edits re-parse the parameters, but parameter edits never flow back into the URL:

```js
const u = new URL("https://x.dev/?x=1");

u.search = "y=2";                 // URL → params
u.searchParams.get("y");          // "2"

u.searchParams.append("z", "3");  // params ✗→ URL
u.href;                           // "https://x.dev/?y=2"  — z is lost
```

## Passing URLs to `fetch`

`fetch()` takes a **string**, not a `URL` object — it looks for a `.url` property, which a `URL` instance does not have:

```js
(async () => {
  const u = new URL("https://example.com/x");
  await fetch(u);        // rejects with the string "Invalid URL"
  await fetch(u.href);   // fetches — always pass u.href
})();
```

Note that `fetch` rejections here are plain **strings**, not `Error` objects (for example `"Invalid URL"` and `"Network error"`).

## Patterns

### Parse a request URL

```js
http.serve({ port: 3000 }, (raw, method) => {
  const u = new URL(raw, "http://localhost");
  if (u.pathname === "/health") return Response.json({ ok: true });
  return Response.json({ path: u.pathname, page: u.searchParams.get("page") });
});
```

## Gotchas

- `searchParams.size` and `Headers.size` are **functions** — call them (`sp.size()`); they are not numeric properties.
- `origin` is read-only — change the host with `href = …`.
- Setter inputs longer than 8192 bytes, and malformed setter inputs, are **silently ignored** (no throw).
- Protocol-relative inputs (`"//host/path"`) are treated as root-relative paths, not host replacements.
- Query values are never percent-encoded on output, while the URL parser **decodes** `%XX` on input. Encode with `encodeURIComponent` and keep encoded strings out of `new URL` / `.search`.
- `fetch()` takes a URL *string*, not a `URL` object (`fetch(u)` rejects with `"Invalid URL"` — use `fetch(u.href)`).
- `for...of` does not work on `URLSearchParams` (or `Headers`) — iterate `.entries()` instead.
- `URL.parse` returns `null`; the **constructor throws**. Pick per context.
- There is no `Symbol.iterator` on `URLSearchParams`; `entries` / `keys` / `values` return arrays.
- The constructor stringifies its argument (`new URL(otherUrl)` works), but calling `URL()` without `new` throws.
- `URL.canParse` exists here, so you don't need a fallback for old environments.

## See also

- [`fetch`](/docs/api/fetch) — passing URLs to `fetch`
- [Request / Response](/docs/api/request-response)
- [Compatibility](/docs/reference/compatibility)
