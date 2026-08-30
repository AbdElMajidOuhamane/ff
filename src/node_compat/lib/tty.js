"use strict";
module.exports = {
    isatty: function () { return false; },
    ReadStream: function () { throw new Error("tty.ReadStream not implemented"); },
    WriteStream: function () { throw new Error("tty.WriteStream not implemented"); },
};
