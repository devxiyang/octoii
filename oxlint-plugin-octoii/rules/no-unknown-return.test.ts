import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-unknown-return");

rule.valid("a function that returns JSON", "function value(): JsonValue { return null; }");
rule.valid("an async function that returns a JSON object", "async function load(): Promise<JsonObject> { return {}; }");
rule.valid("a function that returns its type parameter", "function pass<T>(value: T): T { return value; }");
rule.valid("a type guard over unknown", "function isEntry(value: unknown): value is Entry { return true; }");
rule.valid("a promise of nothing", "function run(): Promise<void> { return Promise.resolve(); }");

rule.invalid(
	"a function that returns unknown",
	"function field(object: JsonObject, name: string): unknown { return object[name]; }",
	"field returns `unknown`: return JSON, a schema's type, or a type parameter.",
);
rule.invalid("an async function that returns a promise of unknown", "async function fetchBody(): Promise<unknown> { return null; }", 1);
rule.invalid("an arrow function that returns a thenable of unknown", "const read = (): PromiseLike<unknown> => Promise.resolve(1);", 1);
rule.invalid("a method signature and a function type in a type", "type Bridge = { call(name: string): unknown; next: () => Promise<unknown> };", 2);
