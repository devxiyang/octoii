/*
 * A script on QuickJS: an engine of its own, its runtime and its context, run from its TypeScript as the body of an
 * async function — many at once, each stepped by one thread at a time. The host's functions it is given are under a
 * global object the host names, as Math holds its own, each call a promise the host settles: a step runs the script
 * until it waits on calls, ends, fails or spends its steps, and the host takes the calls it made. Steps are the engine's interrupt ticks, counted, not timed, so a
 * script stops at the same point every time; its clocks tell the time its host gives each step, and its random numbers
 * come of the seed it starts with, so a host replaying it with the same times, seed and settlements sees it run alike.
 * What the engine holds for it — its calls, the lines it wrote — counts against its memory, as its values do.
 */
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

enum {
  ENGINE_DONE = 0,
  ENGINE_WAITING = 1,
  ENGINE_FAILED = 2,
  ENGINE_OUT_OF_STEPS = 3,
};

/* Bytes the host owns, which it frees with engine_free. */
typedef struct EngineText {
  char *bytes;
  size_t len;
} EngineText;

/* A call the script made: its id, its function and its arguments as JSON, the engine's until it is settled. */
typedef struct EngineCall {
  uint32_t id;
  const char *function;
  size_t function_len;
  const char *arguments;
  size_t arguments_len;
} EngineCall;

/* What the script came to: the value it returned as JSON, else what it threw — the host's, freed with
   engine_result_free. */
typedef struct EngineResult {
  int returned;
  EngineText value;
  EngineText name;
  EngineText message;
  EngineText stack;
} EngineResult;

typedef struct Call {
  uint32_t id;
  uint32_t function;
  char *arguments;
  size_t arguments_len;
  JSValue resolve;
  JSValue reject;
  int reported;
  struct Call *next;
} Call;

/* A growing buffer of bytes, its memory the runtime's, so it counts against the script's. */
typedef struct {
  char *bytes;
  size_t len;
  size_t capacity;
} Buffer;

typedef struct Engine {
  JSRuntime *runtime;
  JSContext *context;
  JSValue result;
  char *namespace_name;
  char **functions;
  uint32_t function_count;
  Call *calls;
  uint32_t next_id;
  uint64_t steps;
  uint64_t steps_max;
  int out_of_steps;
  int failed;
  JSValue error;
  /* The lines written since they were last taken: their bytes, and where each ends. */
  Buffer output;
  size_t *line_ends;
  size_t line_count;
  size_t line_capacity;
} Engine;

void engine_result_free(EngineResult *result);
void engine_texts_free(EngineText *texts, size_t count);

static int append(JSRuntime *runtime, Buffer *buffer, const char *bytes, size_t len) {
  if (buffer->len + len + 1 > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity * 2 : 256;
    while (capacity < buffer->len + len + 1) capacity *= 2;
    char *grown = js_realloc_rt(runtime, buffer->bytes, capacity);
    if (!grown) return -1;
    buffer->bytes = grown;
    buffer->capacity = capacity;
  }
  memcpy(buffer->bytes + buffer->len, bytes, len);
  buffer->len += len;
  buffer->bytes[buffer->len] = 0;
  return 0;
}

/* A copy of `len` bytes the host owns; 0, or -1 with no memory. */
static int text_of(EngineText *text, const char *bytes, size_t len) {
  text->bytes = malloc(len + 1);
  if (!text->bytes) return -1;
  memcpy(text->bytes, bytes, len);
  text->bytes[len] = 0;
  text->len = len;
  return 0;
}

static int interrupt(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  Engine *engine = opaque;
  engine->steps += 1;
  if (engine->steps <= engine->steps_max) return 0;
  engine->out_of_steps = 1;
  return 1;
}

/* A call of the host's function: its arguments as JSON, a promise the host settles. */
static JSValue call_function(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv, int magic) {
  (void)this_value;
  Engine *engine = JS_GetContextOpaque(context);
  JSValue json = JS_JSONStringify(context, argc > 0 ? argv[0] : JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED);
  if (JS_IsException(json)) return json;
  /* No argument, or none JSON holds, is null. */
  int absent = JS_IsUndefined(json);
  size_t len = 4;
  const char *arguments = absent ? NULL : JS_ToCStringLen(context, &len, json);
  JS_FreeValue(context, json);
  if (!absent && !arguments) return JS_EXCEPTION;
  Call *call = js_mallocz(context, sizeof(Call));
  if (call) call->arguments = js_malloc(context, len + 1);
  if (!call || !call->arguments) {
    js_free(context, call);
    if (arguments) JS_FreeCString(context, arguments);
    return JS_EXCEPTION;
  }
  memcpy(call->arguments, arguments ? arguments : "null", len);
  call->arguments[len] = 0;
  call->arguments_len = len;
  if (arguments) JS_FreeCString(context, arguments);
  JSValue resolving[2];
  JSValue promise = JS_NewPromiseCapability(context, resolving);
  if (JS_IsException(promise)) {
    js_free(context, call->arguments);
    js_free(context, call);
    return promise;
  }
  call->id = ++engine->next_id;
  call->function = (uint32_t)magic;
  call->resolve = resolving[0];
  call->reject = resolving[1];
  call->next = engine->calls;
  engine->calls = call;
  return promise;
}

/* `console.log`, `info`, `warn`, `error` and `debug`: a line of the output, its values apart by spaces. */
static JSValue console_line(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv) {
  (void)this_value;
  Engine *engine = JS_GetContextOpaque(context);
  size_t start = engine->output.len;
  for (int i = 0; i < argc; i++) {
    if (i > 0 && append(engine->runtime, &engine->output, " ", 1)) goto fail;
    JSValue shown = JS_IsString(argv[i]) || !JS_IsObject(argv[i]) ? JS_DupValue(context, argv[i])
                                                                  : JS_JSONStringify(context, argv[i], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(shown)) goto fail;
    size_t len = 0;
    const char *text = JS_ToCStringLen(context, &len, shown);
    JS_FreeValue(context, shown);
    if (!text) goto fail;
    int appended = append(engine->runtime, &engine->output, text, len);
    JS_FreeCString(context, text);
    if (appended) goto fail;
  }
  if (engine->line_count == engine->line_capacity) {
    size_t capacity = engine->line_capacity ? engine->line_capacity * 2 : 16;
    size_t *grown = js_realloc(context, engine->line_ends, capacity * sizeof(size_t));
    if (!grown) goto fail;
    engine->line_ends = grown;
    engine->line_capacity = capacity;
  }
  engine->line_ends[engine->line_count++] = engine->output.len;
  return JS_UNDEFINED;
fail:
  /* The line is no part of the output; its values' exception, or the memory's, is the script's. */
  engine->output.len = start;
  return JS_HasException(context) ? JS_EXCEPTION : JS_ThrowOutOfMemory(context);
}

/* The object at `path` — `a.b` — under `root`, made where it is missing. */
static JSValue object_at(JSContext *context, JSValue root, const char *path, size_t len) {
  JSValue at = JS_DupValue(context, root);
  size_t start = 0;
  for (size_t i = 0; i <= len; i++) {
    if (i < len && path[i] != '.') continue;
    char name[256];
    size_t n = i - start < sizeof name - 1 ? i - start : sizeof name - 1;
    memcpy(name, path + start, n);
    name[n] = 0;
    JSValue next = JS_GetPropertyStr(context, at, name);
    if (!JS_IsObject(next)) {
      JS_FreeValue(context, next);
      next = JS_NewObject(context);
      JS_SetPropertyStr(context, at, name, JS_DupValue(context, next));
    }
    JS_FreeValue(context, at);
    at = next;
    start = i + 1;
  }
  return at;
}

/* Puts each of the host's functions — `functions[i]`, as `group.name` — under the global object it names, and the
   console. */
static void install(Engine *engine, JSContext *context) {
  JSValue global = JS_GetGlobalObject(context);
  JSValue named = JS_NewObject(context);
  for (uint32_t i = 0; i < engine->function_count; i++) {
    const char *name = engine->functions[i];
    const char *dot = strrchr(name, '.');
    JSValue holder = dot ? object_at(context, named, name, (size_t)(dot - name)) : JS_DupValue(context, named);
    const char *leaf = dot ? dot + 1 : name;
    JS_SetPropertyStr(context, holder, leaf, JS_NewCFunctionMagic(context, call_function, leaf, 1, JS_CFUNC_generic_magic, (int)i));
    JS_FreeValue(context, holder);
  }
  JS_SetPropertyStr(context, global, engine->namespace_name, named);
  JSValue console = JS_NewObject(context);
  const char *levels[] = {"log", "info", "warn", "error", "debug"};
  for (size_t i = 0; i < sizeof levels / sizeof levels[0]; i++)
    JS_SetPropertyStr(context, console, levels[i], JS_NewCFunction(context, console_line, levels[i], 1));
  JS_SetPropertyStr(context, global, "console", console);
  JS_FreeValue(context, global);
}

/* A context with the whole language QuickJS gives, Temporal and Intl with it. */
static JSContext *context_of(JSRuntime *runtime) {
  JSContext *context = JS_NewContext(runtime);
  if (!context) return NULL;
  if (JS_AddIntrinsicTemporal(context) || JS_AddIntrinsicIntl(context)) {
    JS_FreeContext(context);
    return NULL;
  }
  return context;
}

static void fail_with_exception(Engine *engine) {
  engine->failed = 1;
  JS_FreeValue(engine->context, engine->error);
  engine->error = JS_GetException(engine->context);
}

/*
 * What a script's body is wrapped in: an async function, so it awaits and returns, opened on the body's first line so
 * the lines stay the model's. A column the engine tells on that line is past the opening, and is told less it.
 */
static const char opening[] = "(async () => {";
static const char closing[] = "\n})";
static const char first_line[] = "script.ts:1:";

static int start(Engine *engine, const char *source, size_t len, const char *namespace_name, size_t namespace_len,
                 const char *functions, size_t functions_len, uint32_t memory_max, uint64_t steps_max, int64_t time, uint64_t seed);

/*
 * Starts a script: its TypeScript, the name of the global object the host's functions are under, their names apart by
 * newlines, its memory in bytes, its steps, the time its clocks tell, in milliseconds since 1970, and the seed of its
 * random numbers; gives its engine, which engine_end frees — NULL where none could be made. Runs it until its first await, as *status says: ENGINE_FAILED where it does
 * not compile or throws first, ENGINE_OUT_OF_STEPS where it spends its steps first, else ENGINE_DONE, and a step goes
 * on.
 */
Engine *engine_start(const char *source, size_t len, const char *namespace_name, size_t namespace_len, const char *functions,
                     size_t functions_len, uint32_t memory_max, uint64_t steps_max, int64_t time, uint64_t seed, int *status) {
  Engine *engine = calloc(1, sizeof(Engine));
  *status = ENGINE_FAILED;
  if (!engine) return NULL;
  *status = start(engine, source, len, namespace_name, namespace_len, functions, functions_len, memory_max, steps_max, time, seed);
  return engine;
}

static int start(Engine *engine, const char *source, size_t len, const char *namespace_name, size_t namespace_len,
                 const char *functions, size_t functions_len, uint32_t memory_max, uint64_t steps_max, int64_t time, uint64_t seed) {
  engine->error = JS_UNDEFINED;
  engine->result = JS_UNDEFINED;
  engine->steps_max = steps_max;
  engine->namespace_name = strndup(namespace_name, namespace_len);
  if (!engine->namespace_name) return ENGINE_FAILED;
  for (size_t i = 0, start = 0; i <= functions_len; i++) {
    if (i < functions_len && functions[i] != '\n') continue;
    if (i > start) {
      char **grown = realloc(engine->functions, (engine->function_count + 1) * sizeof(char *));
      if (!grown) return ENGINE_FAILED;
      engine->functions = grown;
      engine->functions[engine->function_count] = strndup(functions + start, i - start);
      if (!engine->functions[engine->function_count]) return ENGINE_FAILED;
      engine->function_count += 1;
    }
    start = i + 1;
  }
  engine->runtime = JS_NewRuntime();
  if (!engine->runtime) return ENGINE_FAILED;
  JS_SetMemoryLimit(engine->runtime, memory_max);
  JS_SetMaxStackSize(engine->runtime, 256 * 1024);
  JS_SetInterruptHandler(engine->runtime, interrupt, engine);
  engine->context = context_of(engine->runtime);
  if (!engine->context) return ENGINE_FAILED;
  JS_SetContextOpaque(engine->context, engine);
  JS_SetContextTime(engine->context, time);
  JS_SetRandomSeed(engine->context, seed);
  install(engine, engine->context);
  Buffer wrapped = {0};
  if (append(engine->runtime, &wrapped, opening, sizeof opening - 1) || append(engine->runtime, &wrapped, source, len) ||
      append(engine->runtime, &wrapped, closing, sizeof closing - 1)) {
    js_free_rt(engine->runtime, wrapped.bytes);
    return ENGINE_FAILED;
  }
  JSValue body = JS_Eval(engine->context, wrapped.bytes, wrapped.len, "script.ts", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_TYPESCRIPT);
  js_free_rt(engine->runtime, wrapped.bytes);
  /* Called from here, so no frame of what wraps it is in an error's stack. */
  engine->result = JS_IsException(body) ? body : JS_Call(engine->context, body, JS_UNDEFINED, 0, NULL);
  JS_FreeValue(engine->context, body);
  if (JS_IsException(engine->result)) {
    engine->result = JS_UNDEFINED;
    if (engine->out_of_steps) return ENGINE_OUT_OF_STEPS;
    fail_with_exception(engine);
    return ENGINE_FAILED;
  }
  /* Steps spent before its first await end it so, whether the engine threw or its promise was rejected. */
  return engine->out_of_steps ? ENGINE_OUT_OF_STEPS : ENGINE_DONE;
}

/* Runs the script on, its clocks telling `time`, until it waits on calls, ends, fails or spends its steps; on the
   thread that calls, whichever it is. */
int engine_step(Engine *engine, int64_t time) {
  if (engine->failed || !engine->context) return ENGINE_FAILED;
  if (engine->out_of_steps) return ENGINE_OUT_OF_STEPS;
  JS_UpdateStackTop(engine->runtime);
  JS_SetContextTime(engine->context, time);
  for (;;) {
    JSContext *context;
    int ran = JS_ExecutePendingJob(engine->runtime, &context);
    if (ran == 0) break;
    if (ran < 0) {
      if (engine->out_of_steps) return ENGINE_OUT_OF_STEPS;
      fail_with_exception(engine);
      return ENGINE_FAILED;
    }
  }
  if (engine->out_of_steps) return ENGINE_OUT_OF_STEPS;
  switch (JS_PromiseState(engine->context, engine->result)) {
    case JS_PROMISE_FULFILLED:
      return ENGINE_DONE;
    case JS_PROMISE_REJECTED:
      engine->failed = 1;
      JS_FreeValue(engine->context, engine->error);
      engine->error = JS_PromiseResult(engine->context, engine->result);
      return ENGINE_FAILED;
    default:
      if (engine->calls) return ENGINE_WAITING;
      engine->failed = 1;
      engine->error = JS_NewError(engine->context);
      JS_SetPropertyStr(engine->context, engine->error, "message", JS_NewString(engine->context, "the script waits on nothing that will settle"));
      return ENGINE_FAILED;
  }
}

/* The calls the script made since they were last asked for, oldest first: *calls, of *count, which engine_free frees,
   their texts the engine's until each call is settled. 0, or -1 with no memory. */
int engine_calls(Engine *engine, EngineCall **calls, size_t *count) {
  size_t n = 0;
  for (Call *call = engine->calls; call; call = call->next) n += !call->reported;
  *calls = NULL;
  *count = n;
  if (n == 0) return 0;
  *calls = malloc(n * sizeof(EngineCall));
  if (!*calls) return -1;
  /* The list holds the newest first. */
  for (Call *call = engine->calls; call; call = call->next) {
    if (call->reported) continue;
    EngineCall *made = &(*calls)[--n];
    made->id = call->id;
    made->function = engine->functions[call->function];
    made->function_len = strlen(engine->functions[call->function]);
    made->arguments = call->arguments;
    made->arguments_len = call->arguments_len;
    call->reported = 1;
  }
  return 0;
}

/* Settles call `id`: with the JSON `json` where `ok`, else rejected with an Error whose message is `json`'s text. 0, or
   -1 where the script waits on no such call. */
int engine_settle(Engine *engine, uint32_t id, int ok, const char *json, size_t len) {
  Call **link = &engine->calls;
  while (*link && (*link)->id != id) link = &(*link)->next;
  Call *call = *link;
  if (!call) return -1;
  JS_UpdateStackTop(engine->runtime);
  *link = call->next;
  JSValue value;
  if (ok) {
    /* The engine's parser reads to a NUL, which a host's bytes need not end with. */
    char *terminated = js_malloc_rt(engine->runtime, len + 1);
    if (terminated) {
      memcpy(terminated, json, len);
      terminated[len] = 0;
      value = JS_ParseJSON(engine->context, terminated, len, "result");
      js_free_rt(engine->runtime, terminated);
    } else {
      value = JS_ThrowOutOfMemory(engine->context);
    }
    if (JS_IsException(value)) {
      value = JS_GetException(engine->context);
      ok = 0;
    }
  } else {
    value = JS_NewError(engine->context);
    JS_SetPropertyStr(engine->context, value, "message", JS_NewStringLen(engine->context, json, len));
  }
  JSValue settled = JS_Call(engine->context, ok ? call->resolve : call->reject, JS_UNDEFINED, 1, (JSValueConst *)&value);
  JS_FreeValue(engine->context, settled);
  JS_FreeValue(engine->context, value);
  JS_FreeValue(engine->context, call->resolve);
  JS_FreeValue(engine->context, call->reject);
  js_free_rt(engine->runtime, call->arguments);
  js_free_rt(engine->runtime, call);
  return 0;
}

/* `name` of `object` as a string the host owns, empty where it has none. */
static int property_text(JSContext *context, JSValueConst object, const char *name, EngineText *text) {
  JSValue value = JS_GetPropertyStr(context, object, name);
  size_t len = 0;
  const char *bytes = JS_IsUndefined(value) || JS_IsException(value) ? NULL : JS_ToCStringLen(context, &len, value);
  JS_FreeValue(context, value);
  /* A getter that throws leaves the text empty, its exception no one's. */
  if (!bytes) JS_FreeValue(context, JS_GetException(context));
  int made = text_of(text, bytes ? bytes : "", bytes ? len : 0);
  if (bytes) JS_FreeCString(context, bytes);
  return made;
}

/* The error's stack, a column on the body's first line told as the model's: less the opening's. */
static int stack_text(JSContext *context, JSValueConst error, EngineText *text) {
  JSValue value = JS_GetPropertyStr(context, error, "stack");
  size_t len = 0;
  const char *stack = JS_IsUndefined(value) || JS_IsException(value) ? NULL : JS_ToCStringLen(context, &len, value);
  JS_FreeValue(context, value);
  const size_t mark = sizeof first_line - 1;
  const unsigned long opened = sizeof opening - 1;
  text->bytes = malloc(len + 1);
  text->len = 0;
  if (!text->bytes) {
    if (stack) JS_FreeCString(context, stack);
    return -1;
  }
  size_t i = 0;
  while (stack && i < len) {
    if (len - i > mark && memcmp(stack + i, first_line, mark) == 0 && isdigit((unsigned char)stack[i + mark])) {
      char *after = NULL;
      unsigned long column = strtoul(stack + i + mark, &after, 10);
      memcpy(text->bytes + text->len, first_line, mark);
      text->len += mark;
      /* A column less the opening's is no longer than it. */
      text->len += (size_t)snprintf(text->bytes + text->len, (size_t)(after - stack) - i - mark + 1, "%lu",
                                    column > opened ? column - opened : 1);
      i = (size_t)(after - stack);
    } else {
      text->bytes[text->len++] = stack[i++];
    }
  }
  text->bytes[text->len] = 0;
  if (stack) JS_FreeCString(context, stack);
  return 0;
}

/* What `error` says, thrown: an Error's name, message and stack; any other value its JSON as the message. */
static int thrown(JSContext *context, JSValueConst error, EngineResult *result) {
  if (JS_IsError(context, error))
    return property_text(context, error, "name", &result->name) || property_text(context, error, "message", &result->message) ||
           stack_text(context, error, &result->stack);
  JSValue json = JS_JSONStringify(context, error, JS_UNDEFINED, JS_UNDEFINED);
  size_t n = 0;
  const char *text = JS_IsException(json) || JS_IsUndefined(json) ? NULL : JS_ToCStringLen(context, &n, json);
  int made = text_of(&result->name, "Thrown", 6) || text_of(&result->message, text ? text : "undefined", text ? n : 9) ||
             text_of(&result->stack, "", 0);
  if (text) JS_FreeCString(context, text);
  /* A value JSON cannot hold leaves the message "undefined", its exception no one's. */
  if (JS_IsException(json)) JS_FreeValue(context, JS_GetException(context));
  JS_FreeValue(context, json);
  return made;
}

/* What a script returned, as JSON — nothing is null; a value JSON cannot hold, as a BigInt, what saying so threw. */
static int returned(JSContext *context, JSValueConst promise, EngineResult *result) {
  JSValue value = JS_PromiseResult(context, promise);
  JSValue json = JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(context, value);
  if (JS_IsException(json)) {
    JSValue error = JS_GetException(context);
    int made = thrown(context, error, result);
    JS_FreeValue(context, error);
    return made;
  }
  size_t n = 0;
  const char *text = JS_IsUndefined(json) ? NULL : JS_ToCStringLen(context, &n, json);
  JS_FreeValue(context, json);
  result->returned = 1;
  int made = text_of(&result->value, text ? text : "null", text ? n : 4);
  if (text) JS_FreeCString(context, text);
  return made;
}

/* What the script came to: 0 with *result filled, the host's to free with engine_result_free; 1 where it has yet to
   come to anything; -1 with no memory. */
int engine_result(Engine *engine, EngineResult *result) {
  memset(result, 0, sizeof *result);
  int made;
  if (!engine->context) {
    made = text_of(&result->name, "InternalError", 13) || text_of(&result->message, "the script's engine could not be made", 37) ||
           text_of(&result->stack, "", 0);
  } else if (engine->out_of_steps) {
    made = text_of(&result->name, "StepLimit", 9) || text_of(&result->message, "the script ran past its steps", 29) ||
           text_of(&result->stack, "", 0);
  } else if (engine->failed) {
    JS_UpdateStackTop(engine->runtime);
    made = thrown(engine->context, engine->error, result);
  } else if (JS_PromiseState(engine->context, engine->result) != JS_PROMISE_FULFILLED) {
    return 1;
  } else {
    JS_UpdateStackTop(engine->runtime);
    made = returned(engine->context, engine->result, result);
  }
  if (made) engine_result_free(result);
  return made ? -1 : 0;
}

void engine_result_free(EngineResult *result) {
  free(result->value.bytes);
  free(result->name.bytes);
  free(result->message.bytes);
  free(result->stack.bytes);
  memset(result, 0, sizeof *result);
}

/* The lines the script wrote since they were last asked for: *lines, of *count, the host's to free with
   engine_texts_free. 0, or -1 with no memory, the lines kept. */
int engine_output(Engine *engine, EngineText **lines, size_t *count) {
  *lines = NULL;
  *count = engine->line_count;
  if (engine->line_count == 0) return 0;
  *lines = calloc(engine->line_count, sizeof(EngineText));
  if (!*lines) return -1;
  for (size_t i = 0, start = 0; i < engine->line_count; start = engine->line_ends[i++]) {
    if (text_of(&(*lines)[i], engine->output.bytes + start, engine->line_ends[i] - start)) {
      engine_texts_free(*lines, i);
      *lines = NULL;
      return -1;
    }
  }
  engine->output.len = 0;
  engine->line_count = 0;
  return 0;
}

void engine_texts_free(EngineText *texts, size_t count) {
  for (size_t i = 0; i < count; i++) free(texts[i].bytes);
  free(texts);
}

uint64_t engine_steps(Engine *engine) { return engine->steps; }

/* Frees the engine and all it holds. */
void engine_end(Engine *engine) {
  if (!engine) return;
  if (engine->runtime) JS_UpdateStackTop(engine->runtime);
  while (engine->calls) {
    Call *call = engine->calls;
    engine->calls = call->next;
    JS_FreeValue(engine->context, call->resolve);
    JS_FreeValue(engine->context, call->reject);
    js_free_rt(engine->runtime, call->arguments);
    js_free_rt(engine->runtime, call);
  }
  if (engine->context) {
    JS_FreeValue(engine->context, engine->result);
    JS_FreeValue(engine->context, engine->error);
    JS_FreeContext(engine->context);
  }
  if (engine->runtime) {
    js_free_rt(engine->runtime, engine->output.bytes);
    js_free_rt(engine->runtime, engine->line_ends);
    JS_FreeRuntime(engine->runtime);
  }
  for (uint32_t i = 0; i < engine->function_count; i++) free(engine->functions[i]);
  free(engine->functions);
  free(engine->namespace_name);
  free(engine);
}

void engine_free(void *bytes) { free(bytes); }
