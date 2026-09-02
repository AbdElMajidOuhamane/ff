import { check, done } from "./lib.mjs";

const u = new URL("https://example.com:8080/path?q=1#hash");
check("href", u.href === "https://example.com:8080/path?q=1#hash");
check("origin", u.origin === "https://example.com:8080");
check("protocol", u.protocol === "https:");
check("host", u.host === "example.com:8080");
check("hostname", u.hostname === "example.com");
check("port", u.port === "8080");
check("pathname", u.pathname === "/path");
check("search", u.search === "?q=1");
check("hash", u.hash === "#hash");

const u2 = new URL("https://example.com:443/path");
check("default port", u2.port === "");
check("default host", u2.host === "example.com");

const base = new URL("https://example.com/a/b/c");
const rel = new URL("../d", base.href);
check("resolve", rel.pathname === "/a/d");

check("parse", URL.parse("https://example.com") !== null);
check("parse invalid", URL.parse("not a url") === null);
check("canParse valid", URL.canParse("https://example.com") === true);
check("canParse invalid", URL.canParse("not a url") === false);

// setters — regression: empty search/hash must not produce "?" / "#"
const s = new URL("https://example.com/x/y?q=1");
s.pathname = "/z";
check("set pathname", s.href === "https://example.com/z?q=1");
s.search = "a=1&b=2";
check("set search", s.searchParams.get("b") === "2" && s.href === "https://example.com/z?a=1&b=2");
s.search = "";
check("clear search", s.search === "" && s.href === "https://example.com/z");
s.hash = "frag";
check("set hash", s.hash === "#frag");
s.hash = "";
check("clear hash", s.hash === "" && s.href === "https://example.com/z");

done("url");
