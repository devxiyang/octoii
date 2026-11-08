import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-hand-written-parsers");

rule.valid("a guard that checks with a schema", "function isEntry(value: unknown): value is Entry { return matches(EntrySchema, value); }");
rule.valid("a guard of a primitive", "function isText(value: unknown): value is string { return typeof value === 'string'; }");
rule.valid("a guard that reads no field", "function isRecord(value: unknown): value is JsonObject { return isJsonObject(value) && !Array.isArray(value); }");
rule.valid("a guard over a typed union", "blocks.filter((block): block is TextBlock => block.type === 'text');");
rule.valid("a guard over a typed value", "function isTerminal(fiber: Fiber): fiber is TerminalFiber { return fiber.status === 'done'; }");
rule.valid(
	"a guard that calls an array's methods",
	"function isStringList(value: unknown): value is string[] { return Array.isArray(value) && value.every((item) => typeof item === 'string'); }",
);
rule.valid(
	"a guard over a record of typed values",
	"function answersFor(answers: Readonly<Record<string, Answer>>, questions: Q): answers is Answers<Q> { return answers.a !== undefined; }",
);
rule.valid("a parser that uses a schema", "function readSettings(value: unknown): Settings { return parsed(SettingsSchema, value, 'settings'); }");
rule.valid("a narrowing that reads no field", "function describe(value: unknown): string { return isJsonObject(value) ? 'object' : String(value); }");
rule.valid("a read of an array's length", "function size(value: unknown): number { return Array.isArray(value) ? value.length : 0; }");
rule.valid("a narrowing of a typed value's field", "function title(entry: Entry): string { if (!isJsonObject(entry.meta)) return ''; return entry.name; }");
rule.valid("a typeof check that reads no field", "function first(value: unknown): number { return typeof value === 'object' ? 1 : 0; }");
rule.valid(
	"a walk over any JSON by keys held in variables",
	"function equal(a: JsonValue, b: JsonValue): boolean { if (!isJsonObject(a) || !isJsonObject(b)) return false; return Object.keys(a).every((key) => a[key] === b[key]); }",
);
rule.valid(
	"a count of any JSON's keys",
	"function size(value: JsonValue): number { return isJsonObject(value) ? Object.keys(value).length : Array.isArray(value) ? value.length : 0; }",
);

rule.invalid(
	"a guard that reads a field of unknown",
	"function isGrant(value: unknown): value is Grant { return isJsonObject(value) && typeof value.token === 'string'; }",
	"isGrant checks the fields of value by hand: describe them with a schema and use `matches` or `parsed`.",
);
rule.invalid(
	"a guard that tests a key with in",
	"function isPlan(value: JsonValue | undefined): value is Plan { return isJsonObject(value) && 'steps' in value; }",
	1,
);
rule.invalid(
	"a guard that reads fields with Reflect and Object.hasOwn",
	"const isWord = (value: unknown): value is Word => typeof Reflect.get(Object(value), 'text') === 'string' || Object.hasOwn(Object(value), 'x') && Reflect.get(value, 'w') !== undefined;",
	1,
);
rule.invalid(
	"a guard that reads a computed field of a JSON object",
	"function isOutcome(value: JsonObject): value is Outcome { return value['kind'] === 'answered'; }",
	1,
);
rule.invalid(
	"a guard over a record of unknown values",
	"function isLabels(value: Readonly<Record<string, unknown>>): value is Labels { return typeof value.name === 'string'; }",
	1,
);
rule.invalid(
	"a parser that narrows and reads a field",
	"function grantOf(value: unknown): Grant { if (!isJsonObject(value) || typeof value.token !== 'string') throw new Error('grant'); return { token: value.token }; }",
	"grantOf parses the fields of value by hand: describe them with a schema and use `parsed` or `matches`.",
);
rule.invalid("an arrow parser of JSON", "const toPlan = (raw: JsonValue): Plan => (isJsonObject(raw) ? { steps: raw['steps'] } : { steps: [] });", 1);
rule.invalid(
	"a parser that narrows with typeof and reads with Reflect",
	"function nameOf(value: unknown): string | undefined { if (typeof value !== 'object' || value === null) return undefined; return String(Reflect.get(value, 'name')); }",
	1,
);
rule.invalid(
	"each parameter a method parses",
	"class Reader { read(line: unknown, body: unknown): void { if (isRecord(line) && isRecord(body)) use(line.a, body.b); } }",
	2,
);
