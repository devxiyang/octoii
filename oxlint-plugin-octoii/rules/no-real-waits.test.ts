import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-real-waits");

rule.valid("a move of the fake clock", "await clock.advance(1_000);");
rule.valid("a timer of the platform", "const timer = platform.setTimer(() => {}, 10);");
rule.valid("a setTimeout imported from a fake clock", "import { setTimeout } from './fake-clock.ts';\nsetTimeout(() => {}, 1);");
rule.valid("a turn of the event loop with a delay of 0", "await new Promise((resolve) => setTimeout(resolve, 0));");
rule.valid("a turn of the event loop with no delay", "await new Promise((resolve) => setTimeout(resolve));");

rule.invalid(
	"a setTimeout with a delay",
	"await new Promise((resolve) => setTimeout(resolve, 10));",
	"A test does not wait on real time (setTimeout): move the fake clock instead.",
);
rule.invalid("a setInterval", "setInterval(() => {}, 5);", 1);
rule.invalid("a Bun.sleep", "await Bun.sleep(300);", "A test does not wait on real time (Bun.sleep): move the fake clock instead.");
rule.invalid("a setTimeout of globalThis", "globalThis.setTimeout(() => {}, 1);", 1);
rule.invalid("a setInterval with a delay of 0", "setInterval(() => {}, 0);", 1);
rule.invalid("a Bun.sleep of 0", "await Bun.sleep(0);", 1);
rule.invalid("a timer of timers/promises under another name", "import { setTimeout as sleep } from 'node:timers/promises';\nawait sleep(10);", 1);
