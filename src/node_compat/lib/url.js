// Node url — legacy parse/format/resolve over the global WHATWG URL class.
"use strict";

const querystring = require("querystring");

const URL_ = globalThis.URL;

function parse(urlStr, parseQueryString, slashesDenoteHost) {
    if (typeof urlStr !== "string") urlStr = String(urlStr);
    const obj = {
        protocol: null, slashes: null, auth: null, host: null, port: null,
        hostname: null, hash: null, search: null, query: null, pathname: null,
        path: null, href: urlStr,
    };

    let u = null;
    try { u = new URL_(urlStr); } catch (_) {}

    if (u) {
        obj.protocol = u.protocol; // Node legacy keeps the trailing colon
        obj.slashes = true;
        obj.auth = u.username ? (u.password ? u.username + ":" + u.password : u.username) : null;
        obj.host = u.host || null;
        obj.hostname = u.hostname || null;
        obj.port = u.port === "" ? null : u.port; // legacy parse: port is a STRING
        obj.hash = u.hash || null;
        obj.search = u.search || null;
        obj.pathname = u.pathname;
        obj.path = (u.pathname || "") + (u.search || "");
        obj.query = parseQueryString && u.search ? querystring.parse(u.search.slice(1)) : (u.search ? u.search.slice(1) : null);
    } else {
        // relative URL: no host
        const hi = urlStr.indexOf("#");
        const rest = hi === -1 ? urlStr : urlStr.slice(0, hi);
        if (hi !== -1) obj.hash = urlStr.slice(hi);
        const qi = rest.indexOf("?");
        if (qi !== -1) { obj.search = rest.slice(qi); obj.pathname = rest.slice(0, qi); }
        else { obj.pathname = rest; }
        obj.path = (obj.pathname || "") + (obj.search || "");
        obj.query = parseQueryString && obj.search ? querystring.parse(obj.search.slice(1)) : (obj.search ? obj.search.slice(1) : null);
    }
    if (slashesDenoteHost) obj.slashes = obj.slashes || true;
    return obj;
}

function format(urlObj) {
    if (typeof urlObj === "string") return urlObj;
    if (urlObj instanceof URL_) return urlObj.href;
    let out = "";
    if (urlObj.protocol) out += urlObj.protocol + ":";
    if (urlObj.slashes !== false && (urlObj.host || urlObj.hostname)) out += "//";
    if (urlObj.auth) out += urlObj.auth + "@";
    if (urlObj.host) out += urlObj.host;
    else if (urlObj.hostname) out += urlObj.hostname + (urlObj.port ? ":" + urlObj.port : "");
    if (urlObj.pathname) out += urlObj.pathname;
    if (urlObj.search) out += urlObj.search;
    if (urlObj.hash) out += urlObj.hash;
    return out;
}

function resolve(from, to) {
    try { return new URL_(to, from).href; } catch (_) { return to; }
}

class Url {}
Url.prototype.parse = parse;
Url.prototype.format = format;
Url.prototype.resolve = resolve;

module.exports = {
    parse,
    format,
    resolve,
    Url,
    URL: URL_,
    URLSearchParams: globalThis.URLSearchParams,
    domainToASCII: (s) => s,
    domainToUnicode: (s) => s,
    pathToFileURL: (p) => {
        const parts = String(p).split("/").map(encodeURIComponent);
        return new URL_("file://" + (String(p).startsWith("/") ? "" : "/") + parts.join("/"));
    },
    fileURLToPath: (u) => (typeof u === "string" ? u : u.pathname),
};
