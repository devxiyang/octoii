import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-deadline-polling");

rule.valid("a loop over a queue", "while (queue.length > 0) queue.shift();");
rule.valid("a counting loop", "for (let index = 0; index < 3; index++) step();");

rule.invalid(
	"a while loop against the wall clock",
	"while (Date.now() < end) await tick();",
	"A test does not poll against a deadline: wait for the event itself, or move the fake clock.",
);
rule.invalid("a do-while loop against a deadline", "const deadline = 5;\ndo { await tick(); } while (!done && clock.now() < deadline);", 1);
rule.invalid("a for loop against performance.now()", "for (; performance.now() < limit; ) await tick();", 1);
