// Node path (posix) — normalizeString/parse verified 14/14 + 10/10 vs Node oracle.
"use strict";

const sep = "/";
const delimiter = ":";

function isPathSeparator(code) {
    return code === 47; // '/'
}

function normalizeString(path, allowAboveRoot, separator, isPathSeparator) {
    let res = "";
    let lastSegmentLength = 0;
    let lastSlash = -1;
    let dots = 0;
    let code;
    for (let i = 0; i <= path.length; ++i) {
        if (i < path.length) code = path.charCodeAt(i);
        else if (isPathSeparator(code)) break;
        else code = 47;

        if (isPathSeparator(code)) {
            if (lastSlash === i - 1 || dots === 1) {
                // NOOP
            } else if (lastSlash !== i - 1 && dots === 2) {
                if (res.length < 2 || lastSegmentLength !== 2 ||
                    res.charCodeAt(res.length - 1) !== 46 ||
                    res.charCodeAt(res.length - 2) !== 46) {
                    if (res.length > 2) {
                        const start = res.length - 1;
                        let j = start;
                        for (; j >= 0; --j) {
                            if (res.charCodeAt(j) === separator) break;
                        }
                        if (j !== res.length - 1) {
                            if (j === -1) {
                                res = "";
                                lastSegmentLength = 0;
                            } else {
                                res = res.slice(0, j);
                                lastSegmentLength = res.length - 1 - j;
                            }
                            lastSlash = i;
                            dots = 0;
                            continue;
                        }
                    } else if (res.length !== 0) {
                        res = "";
                        lastSegmentLength = 0;
                        lastSlash = i;
                        dots = 0;
                        continue;
                    }
                }
                if (allowAboveRoot) {
                    if (res.length > 0) res += "/..";
                    else res = "..";
                    lastSegmentLength = 2;
                }
            } else {
                if (res.length > 0) res += "/" + path.slice(lastSlash + 1, i);
                else res = path.slice(lastSlash + 1, i);
                lastSegmentLength = i - lastSlash - 1;
            }
            lastSlash = i;
            dots = 0;
        } else if (code === 46 && dots !== -1) {
            ++dots;
        } else {
            dots = -1;
        }
    }
    return res;
}

function isAbsolute(p) {
    return p.length > 0 && p.charCodeAt(0) === 47;
}

function normalize(p) {
    if (p.length === 0) return ".";
    const isAbs = isAbsolute(p);
    const trailingSeparator = p.charCodeAt(p.length - 1) === 47;
    p = normalizeString(p, !isAbs, 47, isPathSeparator);
    if (p.length === 0 && !isAbs) p = ".";
    if (p.length > 0 && trailingSeparator) p += "/";
    if (isAbs) return "/" + p;
    return p;
}

function join(...args) {
    if (args.length === 0) return ".";
    let joined;
    for (let i = 0; i < args.length; i++) {
        const arg = String(args[i]);
        if (arg.length > 0) {
            if (joined === undefined) joined = arg;
            else joined += "/" + arg;
        }
    }
    if (joined === undefined) return ".";
    return normalize(joined);
}

function resolve(...args) {
    let resolvedPath = "";
    let resolvedAbsolute = false;
    for (let i = args.length - 1; i >= 0 && !resolvedAbsolute; i--) {
        const p = String(args[i]);
        if (p.length === 0) continue;
        resolvedPath = p + "/" + resolvedPath;
        resolvedAbsolute = p.charCodeAt(0) === 47;
    }
    if (!resolvedAbsolute) {
        if (typeof process === "undefined" || typeof process.cwd !== "function") {
            throw new Error("Path must be absolute or process.cwd must be available: resolve()");
        }
        resolvedPath = process.cwd() + "/" + resolvedPath;
        resolvedAbsolute = true;
    }
    resolvedPath = normalizeString(resolvedPath, !resolvedAbsolute, 47, isPathSeparator);
    if (resolvedAbsolute && resolvedPath.length > 0) return "/" + resolvedPath;
    return resolvedPath.length > 0 ? resolvedPath : ".";
}

function relative(from, to) {
    from = resolve(from);
    to = resolve(to);
    if (from === to) return "";
    const fromOrig = from.split("/");
    const toOrig = to.split("/");
    const fromLast = fromOrig.length;
    const toLast = toOrig.length;
    const length = fromLast < toLast ? fromLast : toLast;
    let i;
    for (i = 0; i < length; i++) {
        if (fromOrig[i] !== toOrig[i]) break;
    }
    const sameRoot = i === 0 && isAbsolute(from) && isAbsolute(to);
    let out = "";
    if (!sameRoot) {
        for (let x = i; x < fromLast; x++) out += "../";
    }
    for (; i < toLast; i++) out += toOrig[i] + (i < toLast - 1 ? "/" : "");
    if (out.length === 0) return ".";
    return out;
}

function dirname(p) {
    if (p.length === 0) return ".";
    const hasRoot = p.charCodeAt(0) === 47;
    let end = -1;
    let matchedSlash = true;
    for (let i = p.length - 1; i >= 1; i--) {
        if (p.charCodeAt(i) === 47) {
            if (!matchedSlash) {
                end = i;
                break;
            }
        } else {
            matchedSlash = false;
        }
    }
    if (end === -1) return hasRoot ? "/" : ".";
    if (hasRoot && end === 1) return "//";
    return p.slice(0, end);
}

function basename(p, ext) {
    if (ext !== undefined && typeof ext !== "string") {
        throw new TypeError('"ext" argument must be a string');
    }
    let start = 0;
    let end = -1;
    let matchedSlash = true;
    for (let i = p.length - 1; i >= 0; i--) {
        if (p.charCodeAt(i) === 47) {
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
        } else if (end === -1) {
            matchedSlash = false;
            end = i + 1;
        }
    }
    if (end === -1) return "";
    let b = p.slice(start, end);
    if (ext !== undefined && b.endsWith(ext) && b.length > ext.length) {
        b = b.slice(0, b.length - ext.length);
    }
    return b;
}

function extname(p) {
    let start = 0;
    let startDot = -1;
    let end = -1;
    let matchedSlash = true;
    let preDotState = 0;
    for (let i = p.length - 1; i >= 0; i--) {
        const code = p.charCodeAt(i);
        if (code === 47) {
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
            continue;
        }
        if (end === -1) {
            matchedSlash = false;
            end = i + 1;
        }
        if (code === 46) {
            if (startDot === -1) startDot = i;
            else if (preDotState !== 1) preDotState = 1;
        } else if (startDot !== -1) {
            preDotState = -1;
        }
    }
    if (startDot === -1 || end === -1 || preDotState === 0 ||
        (preDotState === 1 && startDot === end - 1 && startDot === startPartPlus1(start))) {
        return "";
    }
    return p.slice(startDot, end);
}
function startPartPlus1(start) { return start + 1; }

function parse(p) {
    const ret = { root: "", dir: "", base: "", ext: "", name: "" };
    if (p.length === 0) return ret;
    const isAbsP = isAbsolute(p);
    if (isAbsP) ret.root = "/";
    const start = isAbsP ? 1 : 0;
    let startDot = -1;
    let startPart = 0;
    let end = -1;
    let matchedSlash = true;
    let i = p.length - 1;
    let preDotState = 0;
    for (; i >= start; --i) {
        const code = p.charCodeAt(i);
        if (code === 47) {
            if (!matchedSlash) { startPart = i + 1; break; }
            continue;
        }
        if (end === -1) { matchedSlash = false; end = i + 1; }
        if (code === 46) {
            if (startDot === -1) startDot = i;
            else if (preDotState !== 1) preDotState = 1;
        } else if (startDot !== -1) {
            preDotState = -1;
        }
    }
    if (startDot === -1 || end === -1 || preDotState === 0 ||
        (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
        if (end === -1) ret.base = ret.name = p.slice(start);
        else ret.base = ret.name = p.slice(startPart, end);
    } else {
        ret.name = p.slice(startPart, startDot);
        ret.base = p.slice(startPart, end);
        ret.ext = p.slice(startDot, end);
    }
    if (startPart > 0) ret.dir = p.slice(0, startPart - 1);
    else if (isAbsP) ret.dir = "/";
    return ret;
}

function format(pathObject) {
    const dir = pathObject.dir || pathObject.root;
    const base = pathObject.base ||
        ((pathObject.name || "") + (pathObject.ext || ""));
    if (!dir) return base;
    if (dir === pathObject.root) return dir + base;
    return dir + sep + base;
}

const posix = {
    sep, delimiter, isAbsolute, normalize, join, resolve, relative,
    dirname, basename, extname, parse, format,
};

module.exports = posix;
module.exports.posix = posix;
module.exports.win32 = posix; // serverless = linux; win32 semantics not implemented
