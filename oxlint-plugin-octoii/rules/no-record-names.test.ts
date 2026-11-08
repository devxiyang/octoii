import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-record-names");

rule.valid("a type named for what it is", "type Grant = { readonly code: string };");
rule.valid("a use of TypeScript's Record", "type Labels = Record<string, string>;");
rule.valid("a variable named record", "const record = { a: 1 };");
rule.valid("a class whose name only starts with Record", "class Recorder {}");

rule.invalid("a type alias", "type HangRecord = { readonly at: number };", "Name the type for what it is, not `Record`: HangRecord.");
rule.invalid("an interface", "interface UserRecord { readonly id: string }", 1);
rule.invalid("an exported class", "export class PropertyRecord {}", 1);
rule.invalid("a class expression", "const Made = class EntryRecord {};", 1);
rule.invalid("an enum", "enum StateRecord { A }", 1);
