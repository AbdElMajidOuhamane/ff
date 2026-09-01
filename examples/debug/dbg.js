process.env.DEBUG = "app:*";
const ms = require("ms");                 // real npm package
const debug = require("debug");           // real npm package
const log = debug("app:main");
console.log("ms:", ms("2 days"), ms(1000), ms("1m"));
log("hello from debug+ms running in fairyfly");
log("count=%d", 42);
