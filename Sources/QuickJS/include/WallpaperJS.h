#ifndef WALLPAPER_JS_H
#define WALLPAPER_JS_H
#include <stddef.h>
#include <stdint.h>
typedef struct LWJSProgram LWJSProgram;
/* operation 0 get, 1 set, 2 delete, 3 clear (key NULL; global 0 screen, 1 global,
   2 both). A get that finds the key sets *result to malloc'd bytes, which the
   bridge frees. Returns 1/0 for set (0: no room), delete and clear, -1 for get. */
typedef int (*lwjs_storage_handler)(void *opaque, int operation, int global, const char *key, size_t key_length,
                                    const char *value, size_t value_length, char **result, size_t *result_length);
LWJSProgram *lwjs_compile(const char *source, char **error);
LWJSProgram *lwjs_compile_modules(const char *source, const char *modules, char **error);
/* `input` is the tagged value tree SceneScriptInput writes. */
char *lwjs_evaluate(LWJSProgram *program, const uint8_t *input, double budget_seconds, char **error);
const char *lwjs_logs(LWJSProgram *program);
/* The meshes emitted by the last evaluation, valid until the next one. */
const uint8_t *lwjs_meshes(LWJSProgram *program, size_t *length);
/* The model layers emitted by the last evaluation (packed by the bridge), valid until the next one. */
const uint8_t *lwjs_models(LWJSProgram *program, size_t *length);
size_t lwjs_memory_usage(LWJSProgram *program);
void lwjs_set_memory_limit(LWJSProgram *program, size_t bytes);
/* The storage the next evaluations use; opaque must outlive them. */
void lwjs_set_storage(LWJSProgram *program, lwjs_storage_handler handler, void *opaque);
void lwjs_destroy(LWJSProgram *program);
void lwjs_free_string(char *string);
#endif
