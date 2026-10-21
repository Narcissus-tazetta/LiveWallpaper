#ifndef WALLPAPER_JS_H
#define WALLPAPER_JS_H
#include <stddef.h>
#include <stdint.h>
typedef struct LWJSProgram LWJSProgram;
LWJSProgram *lwjs_compile(const char *source, char **error);
LWJSProgram *lwjs_compile_modules(const char *source, const char *modules, char **error);
/* `input` is the tagged value tree SceneScriptInput writes. */
char *lwjs_evaluate(LWJSProgram *program, const uint8_t *input, double budget_seconds, char **error);
const char *lwjs_logs(LWJSProgram *program);
/* The meshes emitted by the last evaluation, valid until the next one. */
const uint8_t *lwjs_meshes(LWJSProgram *program, size_t *length);
size_t lwjs_memory_usage(LWJSProgram *program);
void lwjs_set_memory_limit(LWJSProgram *program, size_t bytes);
void lwjs_destroy(LWJSProgram *program);
void lwjs_free_string(char *string);
#endif
