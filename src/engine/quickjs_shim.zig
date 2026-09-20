// src/engine/quickjs_shim.zig
// Thin Zig wrapper around QuickJS C API.
// Imports the translateC-generated module (quickjs_c) and re-exports
// all types, functions, and constants with clean names.
// Static inline C functions are already translated by translateC.
// CHANGED: matched to quickjs-ng v0.16.2.

const qjs_c = @import("quickjs_c");

// ─── Types ──────────────────────────────────────────────────────
pub const Runtime = qjs_c.JSRuntime;
pub const Context = qjs_c.JSContext;
pub const Value = qjs_c.JSValue;
pub const JSValue = qjs_c.JSValue;
pub const JSValueConst = qjs_c.JSValueConst;
pub const Atom = qjs_c.JSAtom;
pub const ClassID = qjs_c.JSClassID;
pub const ClassDef = qjs_c.JSClassDef;
pub const ModuleDef = qjs_c.JSModuleDef;
pub const MemoryUsage = qjs_c.JSMemoryUsage;
pub const PropertyEnum = qjs_c.JSPropertyEnum;
pub const CFunction = qjs_c.JSCFunction;
pub const CFunctionMagic = qjs_c.JSCFunctionMagic;
pub const CFunctionData = qjs_c.JSCFunctionData;
pub const ClassFinalizer = qjs_c.JSClassFinalizer;
pub const ClassGCMark = qjs_c.JSClassGCMark;
pub const ClassCall = qjs_c.JSClassCall;
pub const FunctionListEntry = qjs_c.JSCFunctionListEntry;

// ─── Tag constants ──────────────────────────────────────────────
pub const TAG_FIRST: comptime_int = qjs_c.JS_TAG_FIRST;
pub const TAG_BIG_INT: comptime_int = qjs_c.JS_TAG_BIG_INT;
pub const TAG_SYMBOL: comptime_int = qjs_c.JS_TAG_SYMBOL;
pub const TAG_STRING: comptime_int = qjs_c.JS_TAG_STRING;
pub const TAG_STRING_ROPE: comptime_int = qjs_c.JS_TAG_STRING_ROPE;
pub const TAG_MODULE: comptime_int = qjs_c.JS_TAG_MODULE;
pub const TAG_FUNCTION_BYTECODE: comptime_int = qjs_c.JS_TAG_FUNCTION_BYTECODE;
pub const TAG_OBJECT: comptime_int = qjs_c.JS_TAG_OBJECT;
pub const TAG_INT: comptime_int = qjs_c.JS_TAG_INT;
pub const TAG_BOOL: comptime_int = qjs_c.JS_TAG_BOOL;
pub const TAG_NULL: comptime_int = qjs_c.JS_TAG_NULL;
pub const TAG_UNDEFINED: comptime_int = qjs_c.JS_TAG_UNDEFINED;
pub const TAG_UNINITIALIZED: comptime_int = qjs_c.JS_TAG_UNINITIALIZED;
pub const TAG_CATCH_OFFSET: comptime_int = qjs_c.JS_TAG_CATCH_OFFSET;
pub const TAG_EXCEPTION: comptime_int = qjs_c.JS_TAG_EXCEPTION;
pub const TAG_SHORT_BIG_INT: comptime_int = qjs_c.JS_TAG_SHORT_BIG_INT;
pub const TAG_FLOAT64: comptime_int = qjs_c.JS_TAG_FLOAT64;

// ─── Eval flags ──────────────────────────────────────────────────
pub const EVAL_TYPE_GLOBAL: c_int = qjs_c.JS_EVAL_TYPE_GLOBAL;
pub const EVAL_TYPE_MODULE: c_int = qjs_c.JS_EVAL_TYPE_MODULE;
pub const EVAL_TYPE_DIRECT: c_int = qjs_c.JS_EVAL_TYPE_DIRECT;
pub const EVAL_TYPE_INDIRECT: c_int = qjs_c.JS_EVAL_TYPE_INDIRECT;
pub const EVAL_TYPE_MASK: c_int = qjs_c.JS_EVAL_TYPE_MASK;
pub const EVAL_FLAG_STRICT: c_int = qjs_c.JS_EVAL_FLAG_STRICT;
pub const EVAL_FLAG_COMPILE_ONLY: c_int = qjs_c.JS_EVAL_FLAG_COMPILE_ONLY;
pub const EVAL_FLAG_BACKTRACE_BARRIER: c_int = qjs_c.JS_EVAL_FLAG_BACKTRACE_BARRIER;
pub const EVAL_FLAG_ASYNC: c_int = qjs_c.JS_EVAL_FLAG_ASYNC;

// ─── Property flags ──────────────────────────────────────────────
pub const PROP_CONFIGURABLE: c_int = qjs_c.JS_PROP_CONFIGURABLE;
pub const PROP_WRITABLE: c_int = qjs_c.JS_PROP_WRITABLE;
pub const PROP_ENUMERABLE: c_int = qjs_c.JS_PROP_ENUMERABLE;
pub const PROP_C_W_E: c_int = qjs_c.JS_PROP_C_W_E;
pub const PROP_LENGTH: c_int = qjs_c.JS_PROP_LENGTH;
pub const PROP_TMASK: c_int = qjs_c.JS_PROP_TMASK;
pub const PROP_NORMAL: c_int = qjs_c.JS_PROP_NORMAL;
pub const PROP_GETSET: c_int = qjs_c.JS_PROP_GETSET;
pub const PROP_VARREF: c_int = qjs_c.JS_PROP_VARREF;
pub const PROP_AUTOINIT: c_int = qjs_c.JS_PROP_AUTOINIT;
pub const PROP_THROW: c_int = qjs_c.JS_PROP_THROW;
pub const PROP_THROW_STRICT: c_int = qjs_c.JS_PROP_THROW_STRICT;
pub const PROP_NO_EXOTIC: c_int = qjs_c.JS_PROP_NO_EXOTIC;

// ─── GPN flags ───────────────────────────────────────────────────
pub const GPN_STRING_MASK: c_int = qjs_c.JS_GPN_STRING_MASK;
pub const GPN_SYMBOL_MASK: c_int = qjs_c.JS_GPN_SYMBOL_MASK;
pub const GPN_PRIVATE_MASK: c_int = qjs_c.JS_GPN_PRIVATE_MASK;
pub const GPN_ENUM_ONLY: c_int = qjs_c.JS_GPN_ENUM_ONLY;
pub const GPN_SET_ENUM: c_int = qjs_c.JS_GPN_SET_ENUM;

// ─── Promise states ──────────────────────────────────────────────
pub const PROMISE_PENDING: c_int = qjs_c.JS_PROMISE_PENDING;
pub const PROMISE_FULFILLED: c_int = qjs_c.JS_PROMISE_FULFILLED;
pub const PROMISE_REJECTED: c_int = qjs_c.JS_PROMISE_REJECTED;

// ─── Special values ──────────────────────────────────────────────
// CHANGED: JSValueUnion now uses `int32` (no `uint64` field in v0.16.2).
pub const JS_NULL: qjs_c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = qjs_c.JS_TAG_NULL };
pub const JS_UNDEFINED: qjs_c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = qjs_c.JS_TAG_UNDEFINED };
pub const JS_FALSE: qjs_c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = qjs_c.JS_TAG_BOOL };
pub const JS_TRUE: qjs_c.JSValue = .{ .u = .{ .int32 = 1 }, .tag = qjs_c.JS_TAG_BOOL };
pub const JS_EXCEPTION: qjs_c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = qjs_c.JS_TAG_EXCEPTION };
pub const JS_UNINITIALIZED: qjs_c.JSValue = .{ .u = .{ .int32 = 0 }, .tag = qjs_c.JS_TAG_UNINITIALIZED };

// ─── Runtime ─────────────────────────────────────────────────────
pub const newRuntime = qjs_c.JS_NewRuntime;
pub const freeRuntime = qjs_c.JS_FreeRuntime;
pub const setMemoryLimit = qjs_c.JS_SetMemoryLimit;
pub const setMaxStackSize = qjs_c.JS_SetMaxStackSize;
pub const setGCThreshold = qjs_c.JS_SetGCThreshold;
pub const runGC = qjs_c.JS_RunGC;
pub const setRuntimeOpaque = qjs_c.JS_SetRuntimeOpaque;
pub const getRuntimeOpaque = qjs_c.JS_GetRuntimeOpaque;
pub const updateStackTop = qjs_c.JS_UpdateStackTop;

// ─── Context ─────────────────────────────────────────────────────
pub const newContext = qjs_c.JS_NewContext;
pub const freeContext = qjs_c.JS_FreeContext;
pub const dupContext = qjs_c.JS_DupContext;
pub const getContextOpaque = qjs_c.JS_GetContextOpaque;
pub const setContextOpaque = qjs_c.JS_SetContextOpaque;
pub const getRuntime = qjs_c.JS_GetRuntime;
pub const setClassProto = qjs_c.JS_SetClassProto;
pub const getClassProto = qjs_c.JS_GetClassProto;

// ─── Intrinsics ─────────────────────────────────────────────────
// CHANGED: JS_AddIntrinsicStringNormalize removed in v0.16.2 (unused).
pub const addIntrinsicBaseObjects = qjs_c.JS_AddIntrinsicBaseObjects;
pub const addIntrinsicDate = qjs_c.JS_AddIntrinsicDate;
pub const addIntrinsicEval = qjs_c.JS_AddIntrinsicEval;
pub const addIntrinsicRegExpCompiler = qjs_c.JS_AddIntrinsicRegExpCompiler;
pub const addIntrinsicRegExp = qjs_c.JS_AddIntrinsicRegExp;
pub const addIntrinsicJSON = qjs_c.JS_AddIntrinsicJSON;
pub const addIntrinsicProxy = qjs_c.JS_AddIntrinsicProxy;
pub const addIntrinsicMapSet = qjs_c.JS_AddIntrinsicMapSet;
pub const addIntrinsicTypedArrays = qjs_c.JS_AddIntrinsicTypedArrays;
pub const addIntrinsicPromise = qjs_c.JS_AddIntrinsicPromise;
pub const addIntrinsicWeakRef = qjs_c.JS_AddIntrinsicWeakRef;

// ─── Value constructors ──────────────────────────────────────────
// CHANGED: JS_NewBool / JS_NewString removed in v0.16.2 (unused here;
// booleans are constructed directly with the BOOL tag).
pub const newInt32 = qjs_c.JS_NewInt32;
pub const newInt64 = qjs_c.JS_NewInt64;
pub const newUint32 = qjs_c.JS_NewUint32;
pub const newFloat64 = qjs_c.JS_NewFloat64;
pub const newBigInt64 = qjs_c.JS_NewBigInt64;
pub const newBigUint64 = qjs_c.JS_NewBigUint64;
pub const newStringLen = qjs_c.JS_NewStringLen;
pub const newObject = qjs_c.JS_NewObject;
pub const newObjectClass = qjs_c.JS_NewObjectClass;
pub const newObjectProtoClass = qjs_c.JS_NewObjectProtoClass;
pub const newObjectProto = qjs_c.JS_NewObjectProto;
pub const newArray = qjs_c.JS_NewArray;
pub const newDate = qjs_c.JS_NewDate;
pub const newError = qjs_c.JS_NewError;
pub const newAtomString = qjs_c.JS_NewAtomString;

// ─── Value type checks ───────────────────────────────────────────
// CHANGED: v0.16.2 returns bool — wrapped as c_int to preserve the
// codebase's == 0 / != 0 call convention.
// NOTE: Most JS_Is* functions are static inline with NO ctx param.
// Only JS_IsFunction, JS_IsConstructor, JS_IsInstanceOf take ctx.
pub fn isNumber(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsNumber(val));
}
pub fn isBool(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsBool(val));
}
pub fn isNull(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsNull(val));
}
pub fn isUndefined(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsUndefined(val));
}
pub fn isException(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsException(val));
}
pub fn isUninitialized(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsUninitialized(val));
}
pub fn isString(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsString(val));
}
pub fn isSymbol(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsSymbol(val));
}
pub fn isObject(val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsObject(val));
}
pub fn isFunction(ctx: ?*Context, val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsFunction(ctx, val));
}
pub fn isArray(ctx: ?*Context, val: Value) c_int {
    _ = ctx;
    return @intFromBool(qjs_c.JS_IsArray(val));
}
pub fn isConstructor(ctx: ?*Context, val: Value) c_int {
    return @intFromBool(qjs_c.JS_IsConstructor(ctx, val));
}
pub fn isError(ctx: ?*Context, val: Value) c_int {
    _ = ctx;
    return @intFromBool(qjs_c.JS_IsError(val));
}
pub fn isInstanceOf(ctx: ?*Context, val: Value, obj: Value) c_int {
    return qjs_c.JS_IsInstanceOf(ctx, val, obj);
}
pub fn isNan(val: Value) c_int {
    return @intFromBool(qjs_c.JS_VALUE_IS_NAN(val));
}

// ─── Tag helpers ─────────────────────────────────────────────────
pub const getTag = qjs_c.JS_VALUE_GET_TAG;
pub const isNan2 = qjs_c.JS_VALUE_IS_NAN;

// ─── Value conversion ──────────────────────────────────────────
pub const toBool = qjs_c.JS_ToBool;
pub const toInt32 = qjs_c.JS_ToInt32;
pub const toUint32 = qjs_c.JS_ToUint32;
pub const toInt64 = qjs_c.JS_ToInt64;
pub const toFloat64 = qjs_c.JS_ToFloat64;
pub const toBigInt64 = qjs_c.JS_ToBigInt64;
pub const toIndex = qjs_c.JS_ToIndex;
pub const toString = qjs_c.JS_ToString;
pub const toPropertyKey = qjs_c.JS_ToPropertyKey;
pub const toCStringLen2 = qjs_c.JS_ToCStringLen2;
pub const toCStringLen = qjs_c.JS_ToCStringLen;
pub const toCString = qjs_c.JS_ToCString;
pub const freeCString = qjs_c.JS_FreeCString;

// ─── Reference counting ────────────────────────────────────────
pub const dupValue = qjs_c.JS_DupValue;
pub const freeValue = qjs_c.JS_FreeValue;
pub const freeValueRT = qjs_c.JS_FreeValueRT;

// ─── Property access ───────────────────────────────────────────
pub const getOwnPropertyNames = qjs_c.JS_GetOwnPropertyNames;
pub const freePropertyEnum = qjs_c.JS_FreePropertyEnum;
pub const getPropertyStr = qjs_c.JS_GetPropertyStr;
pub const getPropertyUint32 = qjs_c.JS_GetPropertyUint32;
pub const setPropertyStr = qjs_c.JS_SetPropertyStr;
pub const setPropertyUint32 = qjs_c.JS_SetPropertyUint32;
pub const setPropertyInt64 = qjs_c.JS_SetPropertyInt64;
pub const hasProperty = qjs_c.JS_HasProperty;
pub const isExtensible = qjs_c.JS_IsExtensible;
pub const preventExtensions = qjs_c.JS_PreventExtensions;
pub const setPrototype = qjs_c.JS_SetPrototype;
pub const getPrototype = qjs_c.JS_GetPrototype;
pub const getProperty = qjs_c.JS_GetProperty;
pub const setProperty = qjs_c.JS_SetProperty;
// CHANGED: getPropertyInternal/setPropertyInternal removed in v0.16.2
// (unused by any caller). JS_DeleteProperty (unused) gained a flags param.

// ─── Define properties ──────────────────────────────────────────
pub const defineProperty = qjs_c.JS_DefineProperty;
pub const definePropertyValue = qjs_c.JS_DefinePropertyValue;
pub const definePropertyValueUint32 = qjs_c.JS_DefinePropertyValueUint32;
pub const definePropertyValueStr = qjs_c.JS_DefinePropertyValueStr;
pub const definePropertyGetSet = qjs_c.JS_DefinePropertyGetSet;

// ─── Atom support ───────────────────────────────────────────────
pub const newAtomLen = qjs_c.JS_NewAtomLen;
pub const newAtom = qjs_c.JS_NewAtom;
pub const newAtomUInt32 = qjs_c.JS_NewAtomUInt32;
pub const dupAtom = qjs_c.JS_DupAtom;
pub const freeAtom = qjs_c.JS_FreeAtom;
pub const atomToValue = qjs_c.JS_AtomToValue;
pub const atomToString = qjs_c.JS_AtomToString;
pub const atomToCStringLen = qjs_c.JS_AtomToCStringLen;
pub const atomToCString = qjs_c.JS_AtomToCString;
pub const valueToAtom = qjs_c.JS_ValueToAtom;

// ─── Function creation ─────────────────────────────────────────
pub const newCFunction2 = qjs_c.JS_NewCFunction2;
pub const newCFunction = qjs_c.JS_NewCFunction;
pub const newCFunctionMagic = qjs_c.JS_NewCFunctionMagic;
pub const newCFunctionData = qjs_c.JS_NewCFunctionData;
pub const setConstructor = qjs_c.JS_SetConstructor;
pub const setConstructorBit = qjs_c.JS_SetConstructorBit;
pub const JS_CFUNC_constructor = qjs_c.JS_CFUNC_constructor;
pub const JS_CFUNC_generic_magic = qjs_c.JS_CFUNC_generic_magic;
pub const JS_CFUNC_getter = qjs_c.JS_CFUNC_getter;
pub const JS_CFUNC_setter = qjs_c.JS_CFUNC_setter;

// ─── Function call ──────────────────────────────────────────────
pub const call = qjs_c.JS_Call;
pub const invoke = qjs_c.JS_Invoke;
pub const callConstructor = qjs_c.JS_CallConstructor;
pub const callConstructor2 = qjs_c.JS_CallConstructor2;

// ─── Eval ───────────────────────────────────────────────────────
pub const eval = qjs_c.JS_Eval;
pub const evalThis = qjs_c.JS_EvalThis;
// CHANGED: JS_DetectModule returns bool in v0.16.2 — wrapped as c_int.
pub fn detectModule(input: [*c]const u8, input_len: usize) c_int {
    return @intFromBool(qjs_c.JS_DetectModule(input, input_len));
}

// ─── Global object ─────────────────────────────────────────────
pub const getGlobalObject = qjs_c.JS_GetGlobalObject;

// ─── JSON ───────────────────────────────────────────────────────
pub const parseJSON = qjs_c.JS_ParseJSON;
pub const jsonStringify = qjs_c.JS_JSONStringify;

// ─── ArrayBuffer ────────────────────────────────────────────────
pub const newArrayBuffer = qjs_c.JS_NewArrayBuffer;
pub const getUint8Array = qjs_c.JS_GetUint8Array;
pub const newArrayBufferCopy = qjs_c.JS_NewArrayBufferCopy;
pub const getArrayBuffer = qjs_c.JS_GetArrayBuffer;
pub const detachArrayBuffer = qjs_c.JS_DetachArrayBuffer;

// ─── TypedArray ────────────────────────────────────────────────
pub const newTypedArray = qjs_c.JS_NewTypedArray;
pub const JS_TYPED_ARRAY_UINT8 = qjs_c.JS_TYPED_ARRAY_UINT8;
pub const getTypedArrayBuffer = qjs_c.JS_GetTypedArrayBuffer;

// ─── Promise ────────────────────────────────────────────────────
pub const newPromiseCapability = qjs_c.JS_NewPromiseCapability;
pub const promiseState = qjs_c.JS_PromiseState;
pub const promiseResult = qjs_c.JS_PromiseResult;

// ─── Exceptions ─────────────────────────────────────────────────
pub const throw = qjs_c.JS_Throw;
pub const getException = qjs_c.JS_GetException;
pub const hasException = qjs_c.JS_HasException;
pub const throwTypeError = qjs_c.JS_ThrowTypeError;
pub const throwRangeError = qjs_c.JS_ThrowRangeError;
pub const throwInternalError = qjs_c.JS_ThrowInternalError;
pub const throwSyntaxError = qjs_c.JS_ThrowSyntaxError;
pub const throwOutOfMemory = qjs_c.JS_ThrowOutOfMemory;
pub const throwReferenceError = qjs_c.JS_ThrowReferenceError;
// CHANGED: JS_SetUncatchableException removed in v0.16.2 (unused).

// ─── Job queue ──────────────────────────────────────────────────
pub const isJobPending = qjs_c.JS_IsJobPending;
pub const executePendingJob = qjs_c.JS_ExecutePendingJob;
pub const enqueueJob = qjs_c.JS_EnqueueJob;

// ─── Memory usage ───────────────────────────────────────────────
pub const computeMemoryUsage = qjs_c.JS_ComputeMemoryUsage;

// ─── Opaque data on objects ─────────────────────────────────────
// CHANGED: JS_SetOpaque returns c_int in v0.16.2 — wrapped as void.
pub fn setOpaque(obj: Value, data: ?*anyopaque) void {
    _ = qjs_c.JS_SetOpaque(obj, data);
}
pub const getOpaque = qjs_c.JS_GetOpaque;
pub const getOpaque2 = qjs_c.JS_GetOpaque2;

// ─── Class support ──────────────────────────────────────────────
pub const newClassID = qjs_c.JS_NewClassID; // CHANGED: now (rt, &id) — call sites pass the runtime
pub const newClass = qjs_c.JS_NewClass;
pub const getClassID = qjs_c.JS_GetClassID;
pub const isRegisteredClass = qjs_c.JS_IsRegisteredClass;

// ─── Module support ────────────────────────────────────────────
pub const setModuleLoaderFunc = qjs_c.JS_SetModuleLoaderFunc;
pub const newCModule = qjs_c.JS_NewCModule;
pub const addModuleExport = qjs_c.JS_AddModuleExport;
pub const setModuleExport = qjs_c.JS_SetModuleExport;
pub const getModuleName = qjs_c.JS_GetModuleName;
pub const getModuleNamespace = qjs_c.JS_GetModuleNamespace;
pub const getImportMeta = qjs_c.JS_GetImportMeta;

// ─── Property function list ─────────────────────────────────────
pub const setPropertyFunctionList = qjs_c.JS_SetPropertyFunctionList;

// ─── Interrupt handler ──────────────────────────────────────────
pub const setInterruptHandler = qjs_c.JS_SetInterruptHandler;

// ─── SharedArrayBuffer ──────────────────────────────────────────
pub const setSharedArrayBufferFunctions = qjs_c.JS_SetSharedArrayBufferFunctions;

// ─── Bytecode write/read ────────────────────────────────────────
pub const writeObject = qjs_c.JS_WriteObject;
pub const readObject = qjs_c.JS_ReadObject;
pub const evalFunction = qjs_c.JS_EvalFunction;

// ─── Object write/read flags (structured clone) ─────────────────
// NOTE: BYTECODE deliberately not exposed — JS_READ_OBJ_BYTECODE on
// untrusted input allows hostile bytecode execution (see quickjs.h).
// SAB deliberately not exposed — the engine installs no
// SharedArrayBuffer functions, so SAB values cannot exist yet.
pub const WRITE_OBJ_REFERENCE: c_int = qjs_c.JS_WRITE_OBJ_REFERENCE;
pub const READ_OBJ_REFERENCE: c_int = qjs_c.JS_READ_OBJ_REFERENCE;

// ─── Memory allocation ──────────────────────────────────────────
pub const js_malloc = qjs_c.js_malloc;
pub const js_free = qjs_c.js_free;
pub const js_realloc = qjs_c.js_realloc;
pub const js_mallocz = qjs_c.js_mallocz;
pub const js_strdup = qjs_c.js_strdup;

// ─── Misc ──────────────────────────────────────────────────────
pub const isLiveObject = qjs_c.JS_IsLiveObject;
pub const setIsHTMLDDA = qjs_c.JS_SetIsHTMLDDA;
