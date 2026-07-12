const c = @cImport({
    @cInclude("binding.h");
});

// Platform
pub const Platform = c.Platform;
pub extern "c" fn v8__Platform__NewDefaultPlatform(thread_pool_size: c_int, idle_task_support: c_int) ?*Platform;
pub extern "c" fn v8__Platform__DELETE(platform: ?*Platform) void;
pub extern "c" fn v8__Platform__PumpMessageLoop(platform: ?*Platform, isolate: ?*Isolate, wait_for_work: bool) bool;

// V8 Init
pub extern "c" fn v8__V8__InitializePlatform(platform: ?*Platform) void;
pub extern "c" fn v8__V8__Initialize() void;
pub extern "c" fn v8__V8__Dispose() c_int;
pub extern "c" fn v8__V8__DisposePlatform() void;

// Isolate
pub const Isolate = c.Isolate;
pub extern "c" fn v8__Isolate__New(params: ?*CreateParams) ?*Isolate;
pub extern "c" fn v8__Isolate__Enter(isolate: ?*Isolate) void;
pub extern "c" fn v8__Isolate__Exit(isolate: ?*Isolate) void;
pub extern "c" fn v8__Isolate__Dispose(isolate: ?*Isolate) void;
pub extern "c" fn v8__Isolate__GetCurrentContext(isolate: ?*Isolate) ?*Context;

// CreateParams
pub const CreateParams = c.CreateParams;
pub extern "c" fn v8__Isolate__CreateParams__SIZEOF() usize;
pub extern "c" fn v8__Isolate__CreateParams__CONSTRUCT(buf: ?*CreateParams) void;
pub extern "c" fn v8__ArrayBuffer__Allocator__NewDefaultAllocator() ?*anyopaque;
pub extern "c" fn v8__ArrayBuffer__Allocator__DELETE(alloc: ?*anyopaque) void;

// HandleScope
pub const HandleScope = c.HandleScope;
pub extern "c" fn v8__HandleScope__CONSTRUCT(buf: ?*HandleScope, isolate: ?*Isolate) void;
pub extern "c" fn v8__HandleScope__DESTRUCT(scope: ?*HandleScope) void;

// Context
pub const Context = c.Context;
pub extern "c" fn v8__Context__New(isolate: ?*Isolate, global_tmpl: ?*const ObjectTemplate, global_obj: ?*const Value) ?*Context;
pub extern "c" fn v8__Context__Enter(context: ?*const Context) void;
pub extern "c" fn v8__Context__Exit(context: ?*const Context) void;
pub extern "c" fn v8__Context__Global(context: ?*const Context) ?*const Object;

// Value / Object
pub const Value = c.Value;
pub const Object = c.Object;
pub extern "c" fn v8__Object__New(isolate: ?*Isolate) ?*const Object;
pub extern "c" fn v8__Object__Set(obj: ?*const Object, context: ?*const Context, key: ?*const Value, val: ?*const Value) bool;
pub extern "c" fn v8__Value__ToString(val: ?*const Value, context: ?*const Context) ?*const String;

// String
pub const String = c.String;
pub extern "c" fn v8__String__NewFromUtf8(isolate: ?*Isolate, data: [*:0]const u8, @"type": c_int, length: c_int) ?*const String;
pub extern "c" fn v8__String__Utf8Length(str: ?*const String, isolate: ?*Isolate) c_int;
pub extern "c" fn v8__String__WriteUtf8(str: ?*const String, isolate: ?*Isolate, buf: [*]u8, len: c_int, nchars: ?*c_int, options: c_int) c_int;

// Function
pub const Function = c.Function;
pub const FunctionCallback = c.FunctionCallback;
pub const FunctionCallbackInfo = c.FunctionCallbackInfo;
pub extern "c" fn v8__Function__New__DEFAULT(context: ?*const Context, callback: FunctionCallback) ?*const Function;
pub extern "c" fn v8__FunctionCallbackInfo__GetIsolate(info: ?*const FunctionCallbackInfo) ?*Isolate;
pub extern "c" fn v8__FunctionCallbackInfo__Length(info: ?*const FunctionCallbackInfo) c_int;
pub extern "c" fn v8__FunctionCallbackInfo__INDEX(info: ?*const FunctionCallbackInfo, i: c_int) ?*const Value;

// ReturnValue
pub const ReturnValue = c.ReturnValue;
pub extern "c" fn v8__ReturnValue__Set(ret: ReturnValue, val: ?*const Value) void;
pub extern "c" fn v8__ReturnValue__Get(ret: ReturnValue) ?*const Value;

// Template
pub const Template = c.Template;
pub extern "c" fn v8__Template__Set(self: ?*const Template, key: ?*const Value, val: ?*const Value) void;

// ObjectTemplate
pub const ObjectTemplate = c.ObjectTemplate;
pub extern "c" fn v8__ObjectTemplate__New__DEFAULT(isolate: ?*Isolate) ?*ObjectTemplate;
pub extern "c" fn v8__ObjectTemplate__NewInstance(self: ?*ObjectTemplate, context: ?*const Context) ?*const Object;

// Script
pub const Script = c.Script;
pub const ScriptOrigin = c.ScriptOrigin;
pub extern "c" fn v8__ScriptOrigin__CONSTRUCT(buf: ?*ScriptOrigin, isolate: ?*Isolate, resource_name: ?*const Value) void;
pub extern "c" fn v8__Script__Compile(context: ?*const Context, src: ?*const String, origin: ?*const ScriptOrigin) ?*Script;
pub extern "c" fn v8__Script__Run(script: ?*Script, context: ?*const Context) ?*const Value;

// TryCatch
pub const TryCatch = c.TryCatch;
pub extern "c" fn v8__TryCatch__SIZEOF() usize;
pub extern "c" fn v8__TryCatch__CONSTRUCT(buf: ?*TryCatch, isolate: ?*Isolate) void;
pub extern "c" fn v8__TryCatch__DESTRUCT(self: ?*TryCatch) void;
pub extern "c" fn v8__TryCatch__HasCaught(self: ?*const TryCatch) bool;
pub extern "c" fn v8__TryCatch__Exception(self: ?*const TryCatch) ?*const Value;
pub extern "c" fn v8__TryCatch__StackTrace(self: ?*const TryCatch, context: ?*const Context) ?*const Value;

// Null/Undefined
pub extern "c" fn v8__Null(isolate: ?*Isolate) ?*const Value;
pub extern "c" fn v8__Undefined(isolate: ?*Isolate) ?*const Value;

// Number
pub extern "c" fn v8__Number__New(isolate: ?*Isolate, val: f64) ?*const Value;
