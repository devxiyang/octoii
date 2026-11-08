import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-wall-clock");
const MESSAGE = "A test does not read the wall clock: take the time from the fake clock.";

rule.valid("the fake clock's time", "const now = clock.now();");
rule.valid("a fixed date", "const date = new Date(0);");
rule.valid("a date from the fake clock", "const later = new Date(clock.now() + 1);");

rule.invalid("Date.now()", "const now = Date.now();", MESSAGE);
rule.invalid("performance.now()", "const started = performance.now();", 1);
rule.invalid("new Date() with no argument", "const today = new Date();", 1);
