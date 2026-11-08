//! A script on QuickJS, through `engine.c`: an engine of its own, started from its TypeScript with the host's functions
//! under a global object the host names, the time its clocks tell and the seed of its random numbers; stepped until it
//! waits on the calls it made, ends, fails or spends its steps, each step at the time its host gives; each call settled
//! by the host. Many run at once, each stepped by one thread at a time. Given the same times, seed and settlements, a
//! script runs alike, as a host that replays it needs.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = enum(c_int) { done = 0, waiting = 1, failed = 2, out_of_steps = 3 };

const Engine = opaque {};
const Text = extern struct { bytes: ?[*]u8, len: usize };
const EngineCall = extern struct { id: u32, function: [*]const u8, function_len: usize, arguments: [*]const u8, arguments_len: usize };
const EngineResult = extern struct { returned: c_int, value: Text, name: Text, message: Text, stack: Text };

extern fn engine_start(source: [*]const u8, len: usize, namespace: [*]const u8, namespace_len: usize, functions: [*]const u8, functions_len: usize, memory_max: u32, steps_max: u64, time: i64, seed: u64, status: *c_int) ?*Engine;
extern fn engine_step(engine: *Engine, time: i64) c_int;
extern fn engine_calls(engine: *Engine, calls: *?[*]EngineCall, count: *usize) c_int;
extern fn engine_settle(engine: *Engine, id: u32, ok: c_int, json: [*]const u8, len: usize) c_int;
extern fn engine_result(engine: *Engine, result: *EngineResult) c_int;
extern fn engine_result_free(result: *EngineResult) void;
extern fn engine_output(engine: *Engine, lines: *?[*]Text, count: *usize) c_int;
extern fn engine_texts_free(texts: ?[*]Text, count: usize) void;
extern fn engine_steps(engine: *Engine) u64;
extern fn engine_end(engine: *Engine) void;
extern fn engine_free(bytes: ?*anyopaque) void;

pub const Limits = struct { memory_max: u32 = 64 * 1024 * 1024, steps_max: u64 = 1_000_000 };

/// How a script starts: the global object the host's functions are under, by its name, as Math holds its own, and the
/// functions, each `group.name` under it; its bounds; the time its clocks tell, in milliseconds since 1970, until a step
/// tells another; the seed of its random numbers.
pub const Start = struct {
    namespace: []const u8,
    functions: []const []const u8,
    limits: Limits = .{},
    time: i64,
    seed: u64,
};

/// A call a script made: its id, which settles it; the function, `group.name` under the namespace; its arguments, as
/// JSON.
pub const Call = struct { id: u32, function: []const u8, arguments: []const u8 };

/// What a script came to: the value it returned, as JSON, or what it threw — an error's name, message and stack.
pub const Result = union(enum) {
    returned: []const u8,
    threw: Thrown,

    pub const Thrown = struct { name: []const u8, message: []const u8, stack: []const u8 };
};

/// A script on an engine of its own, with how it stood once started.
pub const Script = struct {
    engine: *Engine,
    started: Status,

    /// Starts `source`, TypeScript, as `how` says, running it to its first await: failed where it does not compile or
    /// throws first, out of steps where it spends them first, else done and a step goes on.
    pub fn start(arena: Allocator, source: []const u8, how: Start) error{OutOfMemory}!Script {
        const names = try std.mem.join(arena, "\n", how.functions);
        var status: c_int = 0;
        const engine = engine_start(source.ptr, source.len, how.namespace.ptr, how.namespace.len, names.ptr, names.len, how.limits.memory_max, how.limits.steps_max, how.time, how.seed, &status) orelse return error.OutOfMemory;
        return .{ .engine = engine, .started = @fromBackingInt(@intCast(status)) };
    }

    /// Runs it on, its clocks telling `time`, until it waits on calls, ends, fails or spends its steps.
    pub fn step(script: Script, time: i64) Status {
        return @fromBackingInt(@intCast(engine_step(script.engine, time)));
    }

    /// The calls it made since they were last asked for, oldest first, in `arena`.
    pub fn calls(script: Script, arena: Allocator) error{OutOfMemory}![]const Call {
        var made: ?[*]EngineCall = null;
        var count: usize = 0;
        if (engine_calls(script.engine, &made, &count) != 0) return error.OutOfMemory;
        defer engine_free(made);
        const taken = try arena.alloc(Call, count);
        for (taken, (made orelse return taken)[0..count]) |*call, each| call.* = .{
            .id = each.id,
            .function = try arena.dupe(u8, each.function[0..each.function_len]),
            .arguments = try arena.dupe(u8, each.arguments[0..each.arguments_len]),
        };
        return taken;
    }

    /// Settles call `id` with the JSON `json`, or rejects it with `json` as its error's message.
    pub fn settle(script: Script, id: u32, ok: bool, json: []const u8) error{UnknownCall}!void {
        if (engine_settle(script.engine, id, @intFromBool(ok), json.ptr, json.len) != 0) return error.UnknownCall;
    }

    /// What it came to, in `arena`; null while it has yet to come to anything.
    pub fn result(script: Script, arena: Allocator) error{OutOfMemory}!?Result {
        var made: EngineResult = undefined;
        switch (engine_result(script.engine, &made)) {
            0 => {},
            1 => return null,
            else => return error.OutOfMemory,
        }
        defer engine_result_free(&made);
        if (made.returned != 0) return .{ .returned = try textIn(arena, made.value) };
        return .{ .threw = .{ .name = try textIn(arena, made.name), .message = try textIn(arena, made.message), .stack = try textIn(arena, made.stack) } };
    }

    /// The lines it wrote since they were last asked for, in `arena`.
    pub fn output(script: Script, arena: Allocator) error{OutOfMemory}![]const []const u8 {
        var made: ?[*]Text = null;
        var count: usize = 0;
        if (engine_output(script.engine, &made, &count) != 0) return error.OutOfMemory;
        defer engine_texts_free(made, count);
        const lines = try arena.alloc([]const u8, count);
        for (lines, (made orelse return lines)[0..count]) |*line, each| line.* = try textIn(arena, each);
        return lines;
    }

    pub fn steps(script: Script) u64 {
        return engine_steps(script.engine);
    }

    /// Frees the script and its engine.
    pub fn end(script: Script) void {
        engine_end(script.engine);
    }
};

fn textIn(arena: Allocator, text: Text) error{OutOfMemory}![]const u8 {
    return arena.dupe(u8, (text.bytes orelse return "")[0..text.len]);
}

/// The time a test's scripts start at: 2026-11-05, 00:00 UTC.
const test_time: i64 = 1_793_836_800_000;

/// Starts `source` with `functions` under the global `host`, as a test's scripts are.
fn startedFor(arena: Allocator, source: []const u8, functions: []const []const u8, limits: Limits) !Script {
    return Script.start(arena, source, .{ .namespace = "host", .functions = functions, .limits = limits, .time = test_time, .seed = 1 });
}

/// The calls the script made since they were last taken, as JSON for a test to compare:
/// `[{"id":1,"function":"a.b","arguments":...}]`, their arguments as they were made.
fn callsText(arena: Allocator, script: Script) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeByte('[');
    for (try script.calls(arena), 0..) |call, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"id\":{d},\"function\":", .{call.id});
        try std.json.Stringify.value(call.function, .{}, &out.writer);
        try out.writer.print(",\"arguments\":{s}}}", .{call.arguments});
    }
    try out.writer.writeByte(']');
    return out.written();
}

/// What the script came to, as JSON for a test to compare: `{"value":...}` or `{"error":{"name","message","stack"}}`.
fn resultText(arena: Allocator, script: Script) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    switch ((try script.result(arena)) orelse return error.NoResult) {
        .returned => |value| try out.writer.print("{{\"value\":{s}}}", .{value}),
        .threw => |thrown| try std.json.Stringify.value(.{ .@"error" = thrown }, .{}, &out.writer),
    }
    return out.written();
}

fn outputText(arena: Allocator, script: Script) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(try script.output(arena), .{}, &out.writer);
    return out.written();
}

test "a script calls its host's functions, awaits them, logs, and returns a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const page = await host.coding.read({ path: "a.md" });
        \\const [x, y] = await Promise.all([host.math.add({ a: 1, b: 2 }), host.math.add({ a: 3, b: 4 })]);
        \\console.log("read", page.lines, { x });
        \\return { first: page.lines[0], sum: x + y };
    ;
    const script = try startedFor(a, source, &.{ "coding.read", "math.add" }, .{});
    defer script.end();
    try std.testing.expectEqual(Status.done, script.started);
    try std.testing.expectEqual(Status.waiting, script.step(test_time));
    try std.testing.expectEqualStrings("[{\"id\":1,\"function\":\"coding.read\",\"arguments\":{\"path\":\"a.md\"}}]", try callsText(a, script));
    // Bytes with no NUL after them, as a host's are.
    try script.settle(1, true, "{\"lines\":[\"# A\"]}xx"[0..17]);
    try std.testing.expectEqual(Status.waiting, script.step(test_time));
    try std.testing.expectEqualStrings("[{\"id\":2,\"function\":\"math.add\",\"arguments\":{\"a\":1,\"b\":2}},{\"id\":3,\"function\":\"math.add\",\"arguments\":{\"a\":3,\"b\":4}}]", try callsText(a, script));
    try script.settle(3, true, "7");
    try script.settle(2, true, "3");
    try std.testing.expectEqual(Status.done, script.step(test_time));
    try std.testing.expectEqualStrings("{\"value\":{\"first\":\"# A\",\"sum\":10}}", try resultText(a, script));
    try std.testing.expectEqualStrings("[\"read [\\\"# A\\\"] {\\\"x\\\":3}\"]", try outputText(a, script));
}

test "a script fails with its error, a rejected call is thrown into it, and its steps bound it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const caught = try startedFor(a, "try { await host.t.fail({}); } catch (e) { return 'caught ' + e.message; }", &.{"t.fail"}, .{});
    defer caught.end();
    try std.testing.expectEqual(Status.done, caught.started);
    try std.testing.expectEqual(Status.waiting, caught.step(test_time));
    _ = try callsText(a, caught);
    try caught.settle(1, false, "no such file");
    try std.testing.expectEqual(Status.done, caught.step(test_time));
    try std.testing.expectEqualStrings("{\"value\":\"caught no such file\"}", try resultText(a, caught));

    const thrown = try startedFor(a, "throw new TypeError('bad');", &.{}, .{});
    defer thrown.end();
    try std.testing.expectEqual(Status.failed, thrown.step(test_time));
    try std.testing.expect(std.mem.indexOf(u8, try resultText(a, thrown), "\"name\":\"TypeError\",\"message\":\"bad\"") != null);

    const unparsed = try startedFor(a, "let = ;", &.{}, .{});
    defer unparsed.end();
    try std.testing.expectEqual(Status.failed, unparsed.started);
    try std.testing.expect(std.mem.indexOf(u8, try resultText(a, unparsed), "SyntaxError") != null);

    const spinning = try startedFor(a, "while (true) {}", &.{}, .{ .steps_max = 1000 });
    defer spinning.end();
    try std.testing.expectEqual(Status.out_of_steps, spinning.started);
    const later = try startedFor(a, "await 0; while (true) {}", &.{}, .{ .steps_max = 1000 });
    defer later.end();
    try std.testing.expectEqual(Status.out_of_steps, later.step(test_time));
    try std.testing.expect(std.mem.indexOf(u8, try resultText(a, later), "StepLimit") != null);

    const stuck = try startedFor(a, "await new Promise(() => {});", &.{}, .{});
    defer stuck.end();
    try std.testing.expectEqual(Status.failed, stuck.step(test_time));
    try std.testing.expect(std.mem.indexOf(u8, try resultText(a, stuck), "waits on nothing") != null);
}

test "scripts run at once, each on its engine: what one does, another knows not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try startedFor(a, "const n = await host.t.get({}); return n * 2;", &.{"t.get"}, .{});
    defer first.end();
    const second = try startedFor(a, "globalThis.mine = 1; const n = await host.t.get({}); return [n, typeof globalThis.mine];", &.{"t.get"}, .{});
    defer second.end();
    try std.testing.expectEqual(Status.waiting, first.step(test_time));
    try std.testing.expectEqual(Status.waiting, second.step(test_time));
    try std.testing.expectEqualStrings("[{\"id\":1,\"function\":\"t.get\",\"arguments\":{}}]", try callsText(a, second));
    try second.settle(1, true, "7");
    try first.settle(1, true, "21");
    try std.testing.expectEqual(Status.done, second.step(test_time));
    try std.testing.expectEqual(Status.done, first.step(test_time));
    try std.testing.expectEqualStrings("{\"value\":42}", try resultText(a, first));
    try std.testing.expectEqualStrings("{\"value\":[7,\"number\"]}", try resultText(a, second));
    // What the first set on its global, the second never sees.
    const third = try startedFor(a, "return typeof globalThis.mine;", &.{}, .{});
    defer third.end();
    try std.testing.expectEqual(Status.done, third.step(test_time));
    try std.testing.expectEqualStrings("{\"value\":\"undefined\"}", try resultText(a, third));
}

test "a script has the whole language QuickJS gives: code made from strings, Proxy, WeakRef, Temporal and Intl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const made = [eval("1 + 1"), new Function("return 2")()];
        \\return { made, kinds: [typeof Proxy, typeof WeakRef, typeof Temporal, typeof Intl], day: Temporal.PlainDate.from("2026-11-05").dayOfWeek };
    ;
    const script = try startedFor(a, source, &.{}, .{});
    defer script.end();
    try std.testing.expectEqual(Status.done, script.started);
    try std.testing.expectEqual(Status.done, script.step(test_time));
    try std.testing.expectEqualStrings("{\"value\":{\"made\":[2,2],\"kinds\":[\"function\",\"function\",\"object\",\"object\"],\"day\":4}}", try resultText(a, script));
}

test "a failure's stack tells the model's places: its lines, and on its first line its columns, no frame of its wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, stack: []const u8 }{
        .{ .source = "null.x;", .stack = "    at <anonymous> (script.ts:1:5)\n" },
        .{ .source = "let = ;", .stack = "    at script.ts:1:7\n" },
        .{ .source = "function f() { null.z; }\nf();", .stack = "    at f (script.ts:1:20)\n    at <anonymous> (script.ts:2:2)\n" },
        .{ .source = "await 0;\n  null.w;", .stack = "    at <anonymous> (script.ts:2:7)\n" },
    };
    for (cases) |case| {
        const script = try startedFor(a, case.source, &.{}, .{});
        defer script.end();
        try std.testing.expectEqual(Status.failed, script.step(test_time));
        const failed = try std.json.parseFromSliceLeaky(struct { @"error": struct { name: []const u8, message: []const u8, stack: []const u8 } }, a, try resultText(a, script), .{});
        try std.testing.expectEqualStrings(case.stack, failed.@"error".stack);
    }
}

/// What `source` comes to, run with no functions to its end, as JSON.
fn ranTo(arena: Allocator, source: []const u8) ![]const u8 {
    const script = try startedFor(arena, source, &.{}, .{});
    defer script.end();
    _ = script.step(test_time);
    return resultText(arena, script);
}

test "TypeScript's types are skipped as the parser reads them, and what is left runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\interface Point { x: number; y?: number; readonly z: string; [k: string]: unknown }
        \\type Pair<T> = [T, T];
        \\declare const outside: number;
        \\declare function elsewhere(x: number): void;
        \\declare global { interface Window { a: 1 } }
        \\declare namespace N { const n: number; }
        \\function add(x: number, y?: number, ...rest: number[]): number { return x + (y ?? 0) + rest.length; }
        \\function withThis(this: { k: number }, n: number): number { return this.k + n; }
        \\function overloaded(x: string): string;
        \\function overloaded(x: number): number;
        \\function overloaded(x: any): any { return x; }
        \\const generic = <T,>(x: T): T => x;
        \\const asyncArrow = async <T>(x: T): Promise<T> => x;
        \\const pair: Pair<number> = [1, 2];
        \\let definite!: number;
        \\definite = 3;
        \\const p = { x: 1 } as Point;
        \\const q = { x: 2 } satisfies Partial<Point>;
        \\const maybe: { v?: { w: number } } = { v: { w: 4 } };
        \\abstract class Shape {
        \\  abstract area(): number;
        \\  abstract readonly kind: string;
        \\  describe(): string { return this.kind + this.area(); }
        \\}
        \\class Square extends Shape implements Iterable<number> {
        \\  readonly kind = "sq";
        \\  [key: string]: unknown;
        \\  declare extra: number;
        \\  private static made: number = 0;
        \\  protected optional?: number;
        \\  side!: number;
        \\  constructor(side: number) { super(); this.side = side; Square.made++; }
        \\  area(): number { return this.side ** 2; }
        \\  public override describe(): string { return "[" + super.describe() + "]"; }
        \\  *[Symbol.iterator](): Iterator<number> { yield this.side; }
        \\  method?(): void;
        \\  overload(x: string): string;
        \\  overload(x: unknown): unknown { return x; }
        \\  static get count(): number { return Square.made; }
        \\}
        \\const square = new Square(3);
        \\const box = new Map<string, Array<number>>([["k", [1]]]);
        \\return {
        \\  add: add(1, 2, 3, 4), withThis: withThis.call({ k: 1 }, 2), length: withThis.length,
        \\  overloaded: overloaded(5), generic: generic("g"), pair, definite, p: p.x, q: q.x, w: maybe.v!.w,
        \\  square: square.describe(), iterated: [...square], keys: Object.keys(square), extra: "extra" in square,
        \\  count: Square.count, box: box.get("k")!.length, async: typeof asyncArrow(1).then,
        \\};
    ;
    try std.testing.expectEqualStrings(
        \\{"value":{"add":5,"withThis":3,"length":1,"overloaded":5,"generic":"g","pair":[1,2],"definite":3,"p":1,"q":2,"w":4,"square":"[sq9]","iterated":[3],"keys":["kind","optional","side"],"extra":false,"count":1,"box":1,"async":"function"}}
    , try ranTo(a, source));
}

test "TypeScript is read as tsc reads it where JavaScript reads otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\function id<T>(x: T): T { return x; }
        \\const a = 1, b = 2, c = 3, t = true, y = 10, z = 20;
        \\const tag = (s: TemplateStringsArray, ...v: number[]) => s.raw[0] + v.length;
        \\const ran: number[] = [];
        \\const asserted = 1 as number
        \\[5].forEach((v) => ran.push(v));
        \\let type = 1;
        \\type
        \\Foo = 7;
        \\var Foo;
        \\return [
        \\  id<number>(4), a < b > c, (1 + 2 as number) * 2, b as number * 3 + 1, 1 + b satisfies number ** 2 - 1,
        \\  id<string>("s"), tag<number>`x${1}`, t ? (y) : z => z, typeof (t ? (n: number): number => n * 2 : null),
        \\  ran, Foo, a as number < b,
        \\];
    ;
    try std.testing.expectEqualStrings("{\"value\":[4,false,6,7,8,\"s\",\"x1\",10,\"function\",[5],7,true]}", try ranTo(a, source));
}

test "TypeScript's corners: patterns and assertions, types of every kind, predicates, variance, ambient forms, namespaces of types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const f = ({ a, b }: { a: number; b: string } = { a: 1, b: "x" }, [c]: [number] = [2]): string => a + b + c;
        \\let x = 1; (x as number) = 2; (<number>x)++; x! += 1;
        \\const u = { k: 1 } as unknown as { k: number }; const v = <number><unknown>"abc";
        \\const f4 = (): (() => number) => () => 7;
        \\type Cond<T> = T extends (infer U extends string)[] ? U : T extends Promise<infer V> ? V : never;
        \\type Mapped<T> = { +readonly [K in keyof T as `get${Capitalize<string & K>}`]+?: () => T[K] };
        \\type Fn = (a: number, b?: string, ...c: number[]) => void; type Ctor = new <T>(x: T) => object;
        \\type Abstract = abstract new () => object; type Lead = | "a" | "b"; type Negative = -1 | 1n;
        \\type Query = typeof globalThis.Math.PI | keyof typeof Math; type Imported = typeof import("./x");
        \\function isString(x: unknown): x is string { return typeof x === "string"; }
        \\function assertNumber(x: unknown): asserts x is number {}
        \\class Pair<in out K, const V = unknown> extends Map<K, V> {}
        \\try { throw 1; } catch (e: unknown) {}
        \\const object = { m<T>(x: T): T { return x; }, get g(): number { return 1; }, async am<T>(): Promise<void> {} };
        \\declare let a1: string, a2: number;
        \\declare module "m" { export const x: number; }
        \\declare module "n";
        \\declare enum Declared { A }
        \\class Private { #p: number = 1; static #q?: string; get p(): number { return this.#p; } }
        \\const [first]: number[] = [5]; const { second }: { second: number } = { second: 6 };
        \\function optional([v]?: number[], { w }?: { w: number }) { return [v, w]; }
        \\class Named { static?: number; static: string = "s"; }
        \\let p, q; [p as number, q satisfies number] = [7, 8]; ({ r: p as number } = { r: 9 });
        \\const pass = <T>(x: T): T => x; const nested = pass<<T>(x: T) => T>((x) => x);
        \\const later = async <T>(value: T)
        \\  : Promise<T> =>
        \\  value;
        \\namespace Types { export type T = string; export interface I {} }
        \\namespace A.B { type Hidden = number; namespace C {} }
        \\namespace Empty {}
        \\return [
        \\  f(), x, u.k, v, f4()(), isString("s"), new Pair<string, number>().size, object.m(2) + object.g, typeof Declared,
        \\  new Private().p, first, second, optional([1], { w: 2 }), new Named().static, p, q, nested(10), typeof later(1).then,
        \\  1 + 1 as number / 2, 1 ** 1 as number ** 2, 1 + 1 as any satisfies number / 2, 2 ** 3 satisfies any as number ** 2,
        \\  <number>1, typeof Types,
        \\];
    ;
    try std.testing.expectEqualStrings("{\"value\":[\"1x2\",4,1,\"abc\",7,true,0,3,\"undefined\",1,5,6,[1,2],\"s\",9,8,10,\"function\",1,1,1,64,1,\"undefined\"]}", try ranTo(a, source));
}

test "JavaScript that TypeScript reads too means what it does: TypeScript's words are names where JavaScript has them so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\var type = 1, declare = 2, abstract = 3, namespace = 4, module = 5, readonly = 6, is = 7, asserts = 8;
        \\var satisfies = 9, keyof = 10, infer = 11, global = 12, out = 13, any = 14;
        \\var a = 1, b = 2;
        \\var n = a
        \\!b;
        \\var o = { async: 1, get: 2, set: 3, static: 4, type: 5, declare: 6 };
        \\class K { static s = 1; get g() { return 2; } readonly = 3; declare() { return 4; } abstract?: number; is = 5; get<T>(x: T) { return x; } set?: number; }
        \\const k = new K();
        \\const re = /[a-z]+(?=\d)/g;
        \\abstract
        \\class AfterAbstract {}
        \\return [
        \\  type + declare + abstract + namespace + module + readonly + is + asserts + satisfies + keyof + infer + global + out + any,
        \\  n, o.async + o.get + o.set + o.static + o.type + o.declare, [K.s, k.g, k.readonly, k.declare(), k.is, k.get(6)],
        \\  "ab1".match(re)[0] + `t${1 + 1}`, typeof AfterAbstract,
        \\];
    ;
    try std.testing.expectEqualStrings("{\"value\":[105,1,21,[1,2,3,4,5,6],\"abt2\",\"function\"]}", try ranTo(a, source));
}

test "what makes code from TypeScript is refused, and a type that does not parse is told, where they stand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = "TypeScript {s} is not supported: only types are erased; write it as JavaScript";
    const cases = [_]struct { source: []const u8, message: []const u8, at: []const u8 }{
        .{ .source = "let a = 1;\nenum Color { Red }", .message = try std.fmt.allocPrint(a, refused, .{"enum"}), .at = "script.ts:2:1" },
        .{ .source = "const enum E { A }", .message = try std.fmt.allocPrint(a, refused, .{"enum"}), .at = "script.ts:1:1" },
        .{ .source = "namespace N { export const x = 1; }", .message = try std.fmt.allocPrint(a, refused, .{"namespace that holds values"}), .at = "script.ts:1:1" },
        .{ .source = "class C { constructor(private x: number) {} }", .message = try std.fmt.allocPrint(a, refused, .{"parameter property"}), .at = "script.ts:1:23" },
        .{ .source = "let x: = 1;", .message = "unexpected token in type: '='", .at = "script.ts:1:8" },
    };
    for (cases) |case| {
        const failed = try std.json.parseFromSliceLeaky(struct { @"error": struct { name: []const u8, message: []const u8, stack: []const u8 } }, a, try ranTo(a, case.source), .{});
        try std.testing.expectEqualStrings("SyntaxError", failed.@"error".name);
        try std.testing.expectEqualStrings(case.message, failed.@"error".message);
        std.testing.expect(std.mem.indexOf(u8, failed.@"error".stack, case.at) != null) catch |err| {
            std.debug.print("{s}\n=> {s}\n", .{ case.source, failed.@"error".stack });
            return err;
        };
    }
}

test "where a script fails, the place told is the model's, its types and all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const failed = try ranTo(a, "const n: number = 1;\nconst v: number = (null as any).x;");
    try std.testing.expect(std.mem.indexOf(u8, failed, "script.ts:2:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, try ranTo(a, "let s: Größe = 1; null.x;"), "script.ts:1:23") != null);
}

test "its clocks tell the time its host gives each step, and its random numbers come of its seed: a replay runs alike" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const before = [Date.now(), new Date().getTime(), Temporal.Now.instant().epochMilliseconds, Math.random()];
        \\await host.t.wait({});
        \\return { before, after: [Date.now(), new Intl.DateTimeFormat("en", { timeZone: "UTC" }).format(), Math.random()] };
    ;
    var runs: [3][]const u8 = undefined;
    for (&runs, [_]u64{ 7, 7, 8 }) |*told, seed| {
        const script = try Script.start(a, source, .{ .namespace = "host", .functions = &.{"t.wait"}, .time = test_time, .seed = seed });
        defer script.end();
        try std.testing.expectEqual(Status.waiting, script.step(test_time));
        _ = try script.calls(a);
        try script.settle(1, true, "null");
        // The answer came a day on.
        try std.testing.expectEqual(Status.done, script.step(test_time + std.time.ms_per_day));
        told.* = try resultText(a, script);
    }
    const ran = try std.json.parseFromSliceLeaky(struct { value: struct { before: [4]f64, after: struct { i64, []const u8, f64 } } }, a, runs[0], .{});
    for (ran.value.before[0..3]) |at| try std.testing.expectEqual(@as(f64, @floatFromInt(test_time)), at);
    try std.testing.expectEqual(test_time + std.time.ms_per_day, ran.value.after[0]);
    try std.testing.expectEqualStrings("11/6/2026", ran.value.after[1]);
    try std.testing.expectEqualStrings(runs[0], runs[1]);
    try std.testing.expect(!std.mem.eql(u8, runs[0], runs[2]));
}
