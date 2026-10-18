#ifndef WALLPAPER_JS_H
#define WALLPAPER_JS_H
#include <stddef.h>
typedef struct LWJSProgram LWJSProgram;
LWJSProgram *lwjs_compile(const char *source, char **error);
LWJSProgram *lwjs_compile_modules(const char *source, const char *modules, char **error);
char *lwjs_evaluate(LWJSProgram *program, const char *input, double budget_seconds, char **error);
const char *lwjs_logs(LWJSProgram *program);
size_t lwjs_memory_usage(LWJSProgram *program);
void lwjs_set_memory_limit(LWJSProgram *program, size_t bytes);
void lwjs_destroy(LWJSProgram *program);
void lwjs_free_string(char *string);
#endif
