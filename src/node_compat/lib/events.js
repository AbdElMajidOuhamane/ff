// Node EventEmitter — Node-compatible _events shape + lazy init for
// mixed-in usage (Express copies the methods onto a plain function).
"use strict";

class EventEmitter {
    constructor(opts) {
        EventEmitter.call(this, opts);
    }
}

function init(emitter, opts) {
    emitter._events = Object.create(null);
    emitter._eventsCount = 0;
    emitter._maxListeners = undefined;
}

function lazyInit(emitter) {
    if (emitter._events === undefined || emitter._events === null) {
        init(emitter);
    }
}

EventEmitter.prototype._events = undefined;
EventEmitter.prototype._eventsCount = 0;
EventEmitter.prototype._maxListeners = undefined;

EventEmitter.defaultMaxListeners = 10;

EventEmitter.call = function (self, opts) {
    if (self._events === undefined || self._events === Object.getPrototypeOf(self)._events) {
        init(self, opts);
    }
    return self;
};

function checkListener(listener) {
    if (typeof listener !== "function") {
        throw new TypeError('The "listener" argument must be of type Function. Received type ' + typeof listener);
    }
}

function addListener(emitter, type, listener, prepend) {
    lazyInit(emitter);
    checkListener(listener);
    if (emitter._events.newListener !== undefined) {
        emitter.emit("newListener", type, listener);
    }
    let existing = emitter._events[type];
    if (existing === undefined) {
        emitter._events[type] = listener;
        emitter._eventsCount++;
    } else if (typeof existing === "function") {
        emitter._events[type] = prepend ? [listener, existing] : [existing, listener];
    } else if (prepend) {
        existing.unshift(listener);
    } else {
        existing.push(listener);
    }
    const m = emitter.getMaxListeners();
    const count = EventEmitter.listenerCount(emitter, type);
    if (count > m) {
        console.warn(
            "MaxListenersExceededWarning: " + count +
            " listeners added for event \"" + type +
            "\". Use emitter.setMaxListeners() to increase the limit."
        );
    }
    return emitter;
}

EventEmitter.prototype.on = function (type, listener) {
    return addListener(this, type, listener, false);
};
EventEmitter.prototype.addListener = EventEmitter.prototype.on;

EventEmitter.prototype.prependListener = function (type, listener) {
    return addListener(this, type, listener, true);
};

function onceWrapper() {
    if (!this.fired) {
        this.target.removeListener(this.type, this.wrapFn);
        this.fired = true;
        switch (arguments.length) {
            case 0: return this.listener.call(this.target);
            case 1: return this.listener.call(this.target, arguments[0]);
            case 2: return this.listener.call(this.target, arguments[0], arguments[1]);
            case 3: return this.listener.call(this.target, arguments[0], arguments[1], arguments[2]);
            default:
                const args = new Array(arguments.length);
                for (let i = 0; i < args.length; i++) args[i] = arguments[i];
                return this.listener.apply(this.target, args);
        }
    }
}

function _onceWrap(target, type, listener) {
    const state = { fired: false, wrapFn: undefined, target, type, listener };
    const wrapped = onceWrapper.bind(state);
    wrapped.listener = listener;
    state.wrapFn = wrapped;
    return wrapped;
}

EventEmitter.prototype.once = function (type, listener) {
    lazyInit(this);
    checkListener(listener);
    this.on(type, _onceWrap(this, type, listener));
    return this;
};

EventEmitter.prototype.prependOnceListener = function (type, listener) {
    lazyInit(this);
    checkListener(listener);
    this.prependListener(type, _onceWrap(this, type, listener));
    return this;
};

function unwrap(x) {
    if (x && typeof x === "function" && x.listener) return x.listener;
    return x;
}

EventEmitter.prototype.removeListener = function (type, listener) {
    lazyInit(this);
    checkListener(listener);
    const list = this._events[type];
    if (list === undefined) return this;
    if (list === listener || (typeof list === "function" && list.listener === listener)) {
        if (this._eventsCount === 1) {
            this._events = Object.create(null);
            this._eventsCount = 0;
        } else {
            delete this._events[type];
            this._eventsCount--;
        }
        if (this._events.removeListener !== undefined) this.emit("removeListener", type, listener);
    } else if (typeof list !== "function") {
        let pos = -1;
        for (let i = list.length - 1; i >= 0; i--) {
            if (list[i] === listener || (list[i].listener && list[i].listener === listener)) {
                pos = i;
                break;
            }
        }
        if (pos < 0) return this;
        const removed = list[pos];
        if (pos === 0) list.shift();
        else list.splice(pos, 1);
        if (list.length === 1) this._events[type] = list[0];
        if (this._events.removeListener !== undefined) this.emit("removeListener", type, unwrap(removed));
    }
    return this;
};

EventEmitter.prototype.off = EventEmitter.prototype.removeListener;

EventEmitter.prototype.removeAllListeners = function (type) {
    lazyInit(this);
    if (type === undefined) {
        this._events = Object.create(null);
        this._eventsCount = 0;
        return this;
    }
    const list = this._events[type];
    if (list !== undefined) {
        if (typeof list === "function") {
            if (this._eventsCount === 1) { this._events = Object.create(null); this._eventsCount = 0; }
            else { delete this._events[type]; this._eventsCount--; }
        } else {
            const removed = list.length;
            if (this._eventsCount === removed) { this._events = Object.create(null); this._eventsCount = 0; }
            else { delete this._events[type]; this._eventsCount -= removed; }
        }
    }
    return this;
};

EventEmitter.prototype.emit = function (type, ...args) {
    lazyInit(this);
    let doError = type === "error";
    const events = this._events;
    if (events !== undefined && doError) doError = events.error === undefined;
    else if (!doError && events === undefined) return false;

    if (doError) {
        const er = args.length > 0 ? args[0] : undefined;
        if (er instanceof Error) throw er;
        throw new TypeError("Unhandled error. (" + String(er) + ")");
    }

    const handler = events ? events[type] : undefined;
    if (handler === undefined) return false;

    if (typeof handler === "function") {
        handler.apply(this, args);
    } else {
        const len = handler.length;
        const listeners = new Array(len); // copy: safe mutation during emit
        for (let i = 0; i < len; i++) listeners[i] = handler[i];
        for (let i = 0; i < len; i++) {
            const l = listeners[i];
            if (l) l.apply(this, args);
        }
    }
    return true;
};

EventEmitter.prototype.listenerCount = function (type) {
    lazyInit(this);
    const list = this._events ? this._events[type] : undefined;
    if (typeof list === "function") return 1;
    else if (list !== undefined) return list.length;
    return 0;
};

EventEmitter.listenerCount = function (emitter, type) {
    return emitter.listenerCount(type);
};

EventEmitter.prototype.getMaxListeners = function () {
    return this._maxListeners === undefined ? EventEmitter.defaultMaxListeners : this._maxListeners;
};

EventEmitter.prototype.setMaxListeners = function (n) {
    if (typeof n !== "number" || n < 0 || Number.isNaN(n)) {
        throw new RangeError('The value of "n" is out of range. It must be a non-negative number.');
    }
    this._maxListeners = n;
    return this;
};

EventEmitter.prototype.listeners = function (type) {
    lazyInit(this);
    const list = this._events[type];
    if (typeof list === "function") return [list];
    if (list === undefined) return [];
    return list.map(unwrap);
};

EventEmitter.prototype.rawListeners = function (type) {
    lazyInit(this);
    const list = this._events[type];
    if (typeof list === "function") return [list];
    if (list === undefined) return [];
    return list.slice();
};

EventEmitter.prototype.eventNames = function () {
    lazyInit(this);
    return this._eventsCount > 0 ? Object.keys(this._events) : [];
};

module.exports = EventEmitter;
module.exports.EventEmitter = EventEmitter;
module.exports.defaultMaxListeners = EventEmitter.defaultMaxListeners;
module.exports.init = EventEmitter.call;
module.exports.listenerCount = EventEmitter.listenerCount;
