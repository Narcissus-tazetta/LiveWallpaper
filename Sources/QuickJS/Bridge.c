#include "WallpaperJS.h"
#include "quickjs.h"
#include "DrawHelpers.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

struct LWJSProgram {
    JSRuntime *runtime;
    uint8_t *bytecode;
    size_t length;
    uint8_t *helpers;
    size_t helpers_length;
    double deadline;
    int timed_out;
    char logs[4096];
    JSContext *module_context;
    JSValue module_sources;
    JSValue module_entry;
    JSValue module_namespace;
    int module_started;
    size_t log_length;
    int log_count;
    /* Meshes a script emitted during one evaluation: per mesh a parent and a material
       (length-prefixed strings) and a length-prefixed run of float32. */
    uint8_t *meshes;
    size_t mesh_length;
    size_t mesh_capacity;
    /* The layers made from a script's own geometry, as the bridge packs them. */
    uint8_t *models;
    size_t model_length;
    size_t model_capacity;
    lwjs_storage_handler storage;
    void *storage_opaque;
};

#define LWJS_MAX_MESH_BYTES (32u * 1024 * 1024)

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

static void update_stack_limit(JSRuntime *runtime) {
    uintptr_t marker;
    pthread_t thread = pthread_self();
    uintptr_t bottom = (uintptr_t)pthread_get_stackaddr_np(thread) - pthread_get_stacksize_np(thread);
    size_t available = (uintptr_t)&marker - bottom;
    // Dispatch and Swift worker stacks can be smaller than the VM's fixed ceiling.
    // Leave half the remaining native stack for engine frames and error cleanup.
    size_t limit = available / 2;
    JS_UpdateStackTop(runtime);
    JS_SetMaxStackSize(runtime, limit < 512 * 1024 ? limit : 512 * 1024);
}

static int interrupt(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    LWJSProgram *program = opaque;
    if (now() >= program->deadline) program->timed_out = 1;
    return program->timed_out;
}

static void describe_error(LWJSProgram *program, JSContext *context, char **error) {
    JSValue exception = JS_GetException(context);
    if (program->timed_out) {
        *error = strdup("Execution time limit exceeded");
    } else {
        const char *message = JS_ToCString(context, exception);
        JSValue stack = JS_GetPropertyStr(context, exception, "stack");
        const char *trace = JS_IsException(stack) ? NULL : JS_ToCString(context, stack);
        if (program->timed_out) {
            *error = strdup("Execution time limit exceeded");
        } else {
            const char *description = message ? message : "JavaScript evaluation failed";
            size_t a = strnlen(description, 2048);
            size_t b = trace ? strnlen(trace, 2048) : 0;
            *error = malloc(a + b + 2);
            memcpy(*error, description, a);
            (*error)[a] = '\n';
            if (b) memcpy(*error + a + 1, trace, b);
            (*error)[a + b + 1] = 0;
        }
        if (trace) JS_FreeCString(context, trace);
        JS_FreeValue(context, stack);
        if (message) JS_FreeCString(context, message);
    }
    JS_FreeValue(context, exception);
}

static const char *bootstrap =
    "delete globalThis.eval; delete globalThis.Date; delete globalThis.Promise;"
    "delete globalThis.SharedArrayBuffer; delete globalThis.Atomics;"
    "delete Array.fromAsync;"
    "Object.defineProperty(Function.prototype, 'constructor', {value: undefined});"
    "Object.defineProperty(Object.getPrototypeOf(async function(){}), 'constructor', {value: undefined});"
    "Object.defineProperty(Object.getPrototypeOf(function*(){}), 'constructor', {value: undefined});"
    "Object.defineProperty(Object.getPrototypeOf(async function*(){}), 'constructor', {value: undefined});"
    "delete globalThis.Function;"
    "Math.random = () => { throw new Error('Use random(seed, key) instead of Math.random'); };"
    "globalThis.random = (seed, key = 0) => {"
    " let n = (seed | 0) ^ Math.imul(key | 0, 0x9e3779b9);"
    " n = Math.imul(n ^ (n >>> 16), 0x21f0aaad);"
    " n = Math.imul(n ^ (n >>> 15), 0x735a2d97);"
    " return ((n ^ (n >>> 15)) >>> 0) / 4294967296; };"
    "globalThis.clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);"
    "globalThis.lerp = (a, b, t) => a + (b - a) * t;"
    "globalThis.smoothstep = (a, b, v) => {let t = clamp((v-a)/(b-a),0,1); return t*t*(3-2*t);};"
    "globalThis.wave = (phase, cycles = 1, offset = 0) => Math.sin(2*Math.PI*(phase*cycles+offset));"
    "globalThis.noise = (x, seed=0) => {let i=Math.floor(x),t=x-i; return lerp(random(seed,i),random(seed,i+1),t*t*(3-2*t));};"
    "globalThis.hsv = (h,s,v,alpha=1) => {h=((h%1)+1)%1; const f=n=>{let k=(n+h*6)%6;"
    " return v*(1-s*Math.max(0,Math.min(k,4-k,1)));}; return {red:f(5),green:f(3),blue:f(1),alpha};};"
    LWJS_DRAW_HELPERS;

static JSValue console_log(JSContext *context, JSValueConst this_value, int count, JSValueConst *values) {
    (void)this_value;
    LWJSProgram *program = JS_GetContextOpaque(context);
    if (program->log_count++ >= 16 || program->log_length >= sizeof(program->logs) - 2) return JS_UNDEFINED;
    for (int i = 0; i < count; i++) {
        size_t length;
        const char *text = JS_ToCStringLen(context, &length, values[i]);
        if (!text) return JS_EXCEPTION;
        size_t room = sizeof(program->logs) - program->log_length - 2;
        if (length > room) length = room;
        memcpy(program->logs + program->log_length, text, length);
        program->log_length += length;
        program->logs[program->log_length++] = i + 1 == count ? '\n' : ' ';
        program->logs[program->log_length] = 0;
        JS_FreeCString(context, text);
        if (program->log_length >= sizeof(program->logs) - 2) break;
    }
    return JS_UNDEFINED;
}

static int append_bytes(uint8_t **buffer, size_t *used, size_t *reserved, const void *bytes, size_t length) {
    if (length > LWJS_MAX_MESH_BYTES - *used) return -1;
    size_t needed = *used + length;
    if (needed > *reserved) {
        size_t capacity = *reserved ? *reserved : 65536;
        while (capacity < needed) capacity *= 2;
        uint8_t *grown = realloc(*buffer, capacity);
        if (!grown) return -1;
        *buffer = grown;
        *reserved = capacity;
    }
    memcpy(*buffer + *used, bytes, length);
    *used = needed;
    return 0;
}

static int append_mesh_bytes(LWJSProgram *program, const void *bytes, size_t length) {
    return append_bytes(&program->meshes, &program->mesh_length, &program->mesh_capacity, bytes, length);
}

static int append_mesh_string(LWJSProgram *program, JSContext *context, JSValueConst value) {
    size_t length;
    const char *text = JS_ToCStringLen(context, &length, value);
    if (!text) return -1;
    uint32_t prefix = (uint32_t)length;
    int failed = length > 4096 || append_mesh_bytes(program, &prefix, 4) < 0 || append_mesh_bytes(program, text, length) < 0;
    JS_FreeCString(context, text);
    return failed ? -1 : 0;
}

/* emitMesh(parent, material, float32Array, floatCount): the quads of one mesh. */
static JSValue emit_mesh(JSContext *context, JSValueConst this_value, int count, JSValueConst *values) {
    (void)this_value;
    LWJSProgram *program = JS_GetContextOpaque(context);
    if (count != 4) return JS_ThrowTypeError(context, "emitMesh expects a parent, a material, a Float32Array and a count");
    size_t offset, byte_length, element;
    JSValue buffer = JS_GetTypedArrayBuffer(context, values[2], &offset, &byte_length, &element);
    if (JS_IsException(buffer)) return JS_EXCEPTION;
    size_t capacity;
    uint8_t *data = JS_GetArrayBuffer(context, &capacity, buffer);
    int64_t floats;
    if (!data || element != 4 || JS_ToInt64(context, &floats, values[3]) < 0 || floats < 0 ||
        (uint64_t)floats * 4 > byte_length || offset + byte_length > capacity) {
        JS_FreeValue(context, buffer);
        return JS_ThrowTypeError(context, "emitMesh expects a Float32Array of at least count floats");
    }
    uint32_t prefix = (uint32_t)floats;
    int failed = append_mesh_string(program, context, values[0]) < 0 || append_mesh_string(program, context, values[1]) < 0 ||
                 append_mesh_bytes(program, &prefix, 4) < 0 || append_mesh_bytes(program, data + offset, (size_t)floats * 4) < 0;
    JS_FreeValue(context, buffer);
    if (failed) return JS_ThrowRangeError(context, "Mesh output exceeds its limit");
    return JS_UNDEFINED;
}

/* emitModels(uint8Array): the frame's model layers, packed by the bridge. */
static JSValue emit_models(JSContext *context, JSValueConst this_value, int count, JSValueConst *values) {
    (void)this_value;
    LWJSProgram *program = JS_GetContextOpaque(context);
    if (count != 1) return JS_ThrowTypeError(context, "emitModels expects a Uint8Array");
    size_t offset, byte_length, element;
    JSValue buffer = JS_GetTypedArrayBuffer(context, values[0], &offset, &byte_length, &element);
    if (JS_IsException(buffer)) return JS_EXCEPTION;
    size_t capacity;
    uint8_t *data = JS_GetArrayBuffer(context, &capacity, buffer);
    if (!data || element != 1 || offset + byte_length > capacity) {
        JS_FreeValue(context, buffer);
        return JS_ThrowTypeError(context, "emitModels expects a Uint8Array");
    }
    int failed = append_bytes(&program->models, &program->model_length, &program->model_capacity, data + offset, byte_length);
    JS_FreeValue(context, buffer);
    if (failed) return JS_ThrowRangeError(context, "Model output exceeds its limit");
    return JS_UNDEFINED;
}

/* storage(operation, global, key, json): the host's saved values, read and written
   synchronously so another instance of the scene sees a write in the same frame. */
static JSValue storage(JSContext *context, JSValueConst this_value, int count, JSValueConst *values) {
    (void)this_value;
    LWJSProgram *program = JS_GetContextOpaque(context);
    if (!program->storage) return JS_ThrowTypeError(context, "This script has no storage");
    int32_t operation, global;
    if (count < 3 || JS_ToInt32(context, &operation, values[0]) < 0 || JS_ToInt32(context, &global, values[1]) < 0)
        return JS_EXCEPTION;
    size_t key_length = 0, value_length = 0;
    const char *key = JS_IsString(values[2]) ? JS_ToCStringLen(context, &key_length, values[2]) : NULL;
    if (JS_IsString(values[2]) && !key) return JS_EXCEPTION;
    const char *value = count > 3 && JS_IsString(values[3]) ? JS_ToCStringLen(context, &value_length, values[3]) : NULL;
    char *result = NULL;
    size_t result_length = 0;
    int status = program->storage(program->storage_opaque, operation, global, key, key_length, value, value_length,
                                  &result, &result_length);
    if (key) JS_FreeCString(context, key);
    if (value) JS_FreeCString(context, value);
    if (result) {
        JSValue text = JS_NewStringLen(context, result, result_length);
        free(result);
        return text;
    }
    return status < 0 ? JS_UNDEFINED : JS_NewBool(context, status);
}

static JSContext *new_context(LWJSProgram *program) {
    JSContext *context = JS_NewContextRaw(program->runtime);
    if (!context) return NULL;
    JS_SetContextOpaque(context, program);
    if (JS_AddIntrinsicBaseObjects(context) < 0 ||
        JS_AddIntrinsicEval(context) < 0 || JS_AddIntrinsicJSON(context) < 0 ||
        JS_AddIntrinsicMapSet(context) < 0 || JS_AddIntrinsicTypedArrays(context) < 0 ||
        JS_AddIntrinsicPromise(context) < 0 || JS_AddIntrinsicProxy(context) < 0) {
        JS_FreeContext(context);
        return NULL;
    }
    JS_AddIntrinsicRegExpCompiler(context);
    if (JS_AddIntrinsicRegExp(context) < 0) {
        JS_FreeContext(context);
        return NULL;
    }
    JSValue result;
    if (program->helpers) {
        result = JS_ReadObject(context, program->helpers, program->helpers_length, JS_READ_OBJ_BYTECODE);
        if (!JS_IsException(result)) result = JS_EvalFunction(context, result);
    } else {
        result = JS_Eval(context, bootstrap, strlen(bootstrap), "helpers.js", JS_EVAL_TYPE_GLOBAL);
    }
    if (JS_IsException(result)) {
        JS_FreeValue(context, result);
        JS_FreeContext(context);
        return NULL;
    }
    JS_FreeValue(context, result);
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JS_SetPropertyStr(context, console, "log", JS_NewCFunction(context, console_log, "log", 1));
    JS_SetPropertyStr(context, global, "console", console);
    JS_SetPropertyStr(context, global, "__lwjs_emitMesh", JS_NewCFunction(context, emit_mesh, "emitMesh", 4));
    JS_SetPropertyStr(context, global, "__lwjs_emitModels", JS_NewCFunction(context, emit_models, "emitModels", 1));
    JS_SetPropertyStr(context, global, "__lwjs_storage", JS_NewCFunction(context, storage, "storage", 4));
    JS_FreeValue(context, global);
    return context;
}

LWJSProgram *lwjs_compile(const char *source, char **error) {
    *error = NULL;
    if (strlen(source) > 65536) {
        *error = strdup("Script source exceeds 64 KiB");
        return NULL;
    }
    LWJSProgram *program = calloc(1, sizeof(*program));
    program->runtime = JS_NewRuntime();
    if (!program->runtime) {
        free(program);
        *error = strdup("Could not allocate JavaScript runtime");
        return NULL;
    }
    JS_SetMemoryLimit(program->runtime, 16 * 1024 * 1024);
    update_stack_limit(program->runtime);
    JS_SetCanBlock(program->runtime, false);
    JS_SetInterruptHandler(program->runtime, interrupt, program);
    program->deadline = now() + 0.1;
    JSContext *context = new_context(program);
    if (!context) {
        *error = strdup(program->timed_out ? "Execution time limit exceeded" : "Could not initialize JavaScript runtime");
        lwjs_destroy(program);
        return NULL;
    }
    JSValue helpers = JS_Eval(context, bootstrap, strlen(bootstrap), "helpers.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(helpers)) {
        describe_error(program, context, error);
    } else {
        program->helpers = JS_WriteObject(context, &program->helpers_length, helpers, JS_WRITE_OBJ_BYTECODE);
        if (!program->helpers) describe_error(program, context, error);
    }
    JS_FreeValue(context, helpers);
    if (*error) {
        JS_FreeContext(context);
        lwjs_destroy(program);
        return NULL;
    }
    JSValue compiled = JS_Eval(context, source, strlen(source), "script.js",
                               JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY | JS_EVAL_FLAG_STRICT);
    if (JS_IsException(compiled)) {
        describe_error(program, context, error);
    } else {
        program->bytecode = JS_WriteObject(context, &program->length, compiled, JS_WRITE_OBJ_BYTECODE);
        if (!program->bytecode) describe_error(program, context, error);
    }
    JS_FreeValue(context, compiled);
    JS_FreeContext(context);
    if (*error) {
        lwjs_destroy(program);
        return NULL;
    }
    return program;
}

static JSModuleDef *load_module(JSContext *context, const char *name, void *opaque) {
    LWJSProgram *program = opaque;
    JSValue value = JS_GetPropertyStr(context, program->module_sources, name);
    if (!JS_IsString(value)) {
        JS_FreeValue(context, value);
        JS_ThrowReferenceError(context, "Module is not in this script bundle: %s", name);
        return NULL;
    }
    size_t length;
    const char *source = JS_ToCStringLen(context, &length, value);
    JSValue compiled = source ? JS_Eval(context, source, length, name,
        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY) : JS_EXCEPTION;
    if (source) JS_FreeCString(context, source);
    JS_FreeValue(context, value);
    if (JS_IsException(compiled)) return NULL;
    return JS_VALUE_GET_PTR(compiled);
}

LWJSProgram *lwjs_compile_modules(const char *source, const char *modules, char **error) {
    if (strlen(source) > 65536 || strlen(modules) > 8 * 1024 * 1024) {
        *error = strdup("Script bundle exceeds supported limits");
        return NULL;
    }
    LWJSProgram *program = lwjs_compile("", error);
    if (!program) return NULL;
    program->module_sources = JS_UNDEFINED;
    program->module_entry = JS_UNDEFINED;
    program->module_namespace = JS_UNDEFINED;
    JSContext *context = new_context(program);
    if (!context) {
        *error = strdup("Could not initialize module context");
        lwjs_destroy(program);
        return NULL;
    }
    program->module_context = context;
    program->module_sources = JS_ParseJSON(context, modules, strlen(modules), "modules.json");
    JS_SetModuleLoaderFunc(program->runtime, NULL, load_module, program);
    if (JS_IsException(program->module_sources)) {
        describe_error(program, context, error);
    } else {
        program->module_entry = JS_Eval(context, source, strlen(source), "entry.js",
            JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(program->module_entry) || JS_ResolveModule(context, program->module_entry) < 0)
            describe_error(program, context, error);
    }
    if (*error) { lwjs_destroy(program); return NULL; }
    return program;
}

/* Builds the update(context) argument from the tagged input the app writes (see
 * SceneScriptInput.swift), creating values the way JSON.parse would. */
static JSValue decode_input(JSContext *context, const uint8_t **cursor, int depth) {
    if (depth > 512) return JS_ThrowRangeError(context, "Input is too deeply nested");
    const uint8_t *p = *cursor;
    uint8_t tag = *p++;
    uint32_t count = 0;
    JSValue value;
    if (tag >= 4) { memcpy(&count, p, 4); p += 4; }
    switch (tag) {
    case 0: value = JS_NULL; break;
    case 1: value = JS_FALSE; break;
    case 2: value = JS_TRUE; break;
    case 3: {
        double number;
        memcpy(&number, p, 8);
        p += 8;
        value = JS_NewNumber(context, number);
        break;
    }
    case 4:
        value = JS_NewStringLen(context, (const char *)p, count);
        p += count;
        break;
    case 5:
        value = JS_NewArray(context);
        for (uint32_t i = 0; i < count && !JS_IsException(value); i++) {
            JSValue element = decode_input(context, &p, depth + 1);
            if (JS_IsException(element) || JS_DefinePropertyValueUint32(context, value, i, element, JS_PROP_C_W_E) < 0) {
                JS_FreeValue(context, value);
                value = JS_EXCEPTION;
            }
        }
        break;
    default:
        value = JS_NewObject(context);
        for (uint32_t i = 0; i < count && !JS_IsException(value); i++) {
            uint32_t length;
            memcpy(&length, p, 4);
            p += 4;
            int ascii = 1;
            for (uint32_t k = 0; k < length; k++) ascii &= p[k] < 0x80;
            JSAtom key;
            // JS_NewAtomLen matches existing atoms byte by byte as Latin-1, which
            // finds the wrong atom for UTF-8 keys; JSON.parse goes through a string.
            if (ascii) {
                key = JS_NewAtomLen(context, (const char *)p, length);
            } else {
                JSValue name = JS_NewStringLen(context, (const char *)p, length);
                key = JS_IsException(name) ? JS_ATOM_NULL : JS_ValueToAtom(context, name);
                JS_FreeValue(context, name);
            }
            p += length;
            JSValue element = key == JS_ATOM_NULL ? JS_EXCEPTION : decode_input(context, &p, depth + 1);
            if (JS_IsException(element) || JS_DefinePropertyValue(context, value, key, element, JS_PROP_C_W_E) < 0) {
                JS_FreeValue(context, value);
                value = JS_EXCEPTION;
            }
            if (key != JS_ATOM_NULL) JS_FreeAtom(context, key);
        }
        break;
    }
    *cursor = p;
    return value;
}

char *lwjs_evaluate(LWJSProgram *program, const uint8_t *input, double budget_seconds, char **error) {
    *error = NULL;
    program->deadline = now() + budget_seconds;
    program->timed_out = 0;
    program->logs[0] = 0;
    program->log_length = 0;
    program->log_count = 0;
    program->mesh_length = 0;
    program->model_length = 0;
    update_stack_limit(program->runtime);
    JSContext *context = program->module_context ? program->module_context : new_context(program);
    if (!context) {
        *error = strdup(program->timed_out ? "Execution time limit exceeded" : "Could not initialize JavaScript runtime");
        return NULL;
    }
    // Only bytecode produced by lwjs_compile is ever read; packages contain source.
    JSValue result = JS_UNDEFINED;
    if (program->module_context) {
        if (!program->module_started) {
            JSValue entry = program->module_entry;
            program->module_started = 1;
            result = JS_EvalFunction(context, JS_DupValue(context, entry));
            if (!JS_IsException(result) && JS_IsPromise(result)) {
                if (JS_PromiseState(context, result) == JS_PROMISE_REJECTED) {
                    JSValue exception = JS_PromiseResult(context, result);
                    JS_FreeValue(context, result);
                    result = JS_Throw(context, exception);
                } else if (JS_PromiseState(context, result) == JS_PROMISE_PENDING) {
                    JS_FreeValue(context, result);
                    result = JS_ThrowTypeError(context, "Asynchronous module initialization is not supported");
                }
            }
            if (!JS_IsException(result)) {
                program->module_namespace = JS_GetModuleNamespace(context, JS_VALUE_GET_PTR(entry));
                if (JS_IsException(program->module_namespace)) {
                    JS_FreeValue(context, result);
                    result = JS_EXCEPTION;
                }
            }
            JS_FreeValue(context, entry);
            program->module_entry = JS_UNDEFINED;
        }
    } else {
        JSValue compiled = JS_ReadObject(context, program->bytecode, program->length, JS_READ_OBJ_BYTECODE);
        result = JS_IsException(compiled) ? compiled : JS_EvalFunction(context, compiled);
    }
    if (JS_IsException(result)) {
        describe_error(program, context, error);
        JS_FreeValue(context, result);
        if (!program->module_context) JS_FreeContext(context);
        return NULL;
    }
    JS_FreeValue(context, result);
    JSValue global = program->module_context ? JS_DupValue(context, program->module_namespace) : JS_GetGlobalObject(context);
    JSValue function = JS_GetPropertyStr(context, global, "update");
    const uint8_t *cursor = input;
    JSValue argument = decode_input(context, &cursor, 0);
    if (!JS_IsException(argument)) {
        const char *guard_source =
            "c => { for (const key of c._missing || []) Object.defineProperty(c, key,"
            " {get(){throw new Error('Enable the input dependency: '+key);}, configurable:false});"
            " delete c._missing; return c; }";
        JSValue guard_function = JS_Eval(context, guard_source, strlen(guard_source), "inputs.js", JS_EVAL_TYPE_GLOBAL);
        JSValue guarded = JS_IsException(guard_function) ? JS_EXCEPTION : JS_Call(context, guard_function, JS_UNDEFINED, 1, &argument);
        JS_FreeValue(context, guard_function);
        JS_FreeValue(context, argument);
        argument = guarded;
    }
    if (!JS_IsFunction(context, function)) {
        JS_ThrowTypeError(context, "Define function update(context)");
        result = JS_EXCEPTION;
    } else if (JS_IsException(argument)) {
        result = JS_EXCEPTION;
    } else {
        result = JS_Call(context, function, JS_UNDEFINED, 1, &argument);
    }
    char *output = NULL;
    // Async syntax needs Promise classes/finalizers even though async execution is not exposed.
    if (!JS_IsException(result) && (JS_IsPromise(result) || JS_IsJobPending(program->runtime))) {
        JS_FreeValue(context, result);
        result = JS_ThrowTypeError(context, "Only synchronous update(context) is supported");
    }
    if (!JS_IsException(result)) {
        JSValue json = JS_JSONStringify(context, result, JS_UNDEFINED, JS_UNDEFINED);
        if (!JS_IsException(json) && JS_IsJobPending(program->runtime)) {
            JS_FreeValue(context, json);
            json = JS_ThrowTypeError(context, "Only synchronous update(context) is supported");
        }
        if (!JS_IsException(json) && !JS_IsUndefined(json)) {
            size_t length;
            const char *text = JS_ToCStringLen(context, &length, json);
            if (text && length <= 262144 && !program->timed_out) output = strdup(text);
            else JS_ThrowRangeError(context, "Output exceeds 256 KiB or evaluation limit");
            if (text) JS_FreeCString(context, text);
        } else if (JS_IsUndefined(json)) {
            JS_ThrowTypeError(context, "update(context) must return an array of adjustments");
        }
        JS_FreeValue(context, json);
    }
    if (!output) describe_error(program, context, error);
    JS_FreeValue(context, result);
    JS_FreeValue(context, argument);
    JS_FreeValue(context, function);
    JS_FreeValue(context, global);
    if (!program->module_context) JS_FreeContext(context);
    return output;
}

void lwjs_destroy(LWJSProgram *program) {
    if (!program) return;
    free(program->meshes);
    free(program->models);
    if (program->module_context) {
        JS_FreeValue(program->module_context, program->module_entry);
        JS_FreeValue(program->module_context, program->module_namespace);
        JS_FreeValue(program->module_context, program->module_sources);
        JS_FreeContext(program->module_context);
    }
    js_free_rt(program->runtime, program->bytecode);
    js_free_rt(program->runtime, program->helpers);
    JS_FreeRuntime(program->runtime);
    free(program);
}

void lwjs_free_string(char *string) { free(string); }
const char *lwjs_logs(LWJSProgram *program) { return program->logs; }
const uint8_t *lwjs_meshes(LWJSProgram *program, size_t *length) {
    *length = program->mesh_length;
    return program->meshes;
}
const uint8_t *lwjs_models(LWJSProgram *program, size_t *length) {
    *length = program->model_length;
    return program->models;
}
size_t lwjs_memory_usage(LWJSProgram *program) {
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(program->runtime, &usage);
    return (size_t)usage.malloc_size;
}
void lwjs_set_memory_limit(LWJSProgram *program, size_t bytes) { JS_SetMemoryLimit(program->runtime, bytes); }
void lwjs_set_storage(LWJSProgram *program, lwjs_storage_handler handler, void *opaque) {
    program->storage = handler;
    program->storage_opaque = opaque;
}
