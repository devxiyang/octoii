import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-palette-colors");

rule.valid("the design's tokens", 'const c = "bg-muted text-primary border-border hover:bg-accent";');
rule.valid("white and black ink", 'const c = "bg-black/70 text-white";');
rule.valid("a word that only looks like a hue", 'const c = "text-sm text-balance bg-blueprint";');
rule.valid("a hue outside a class", 'const label = "Blue 500";');

rule.invalid(
	"a palette background",
	'const c = "flex bg-zinc-100";',
	"bg-zinc-100 paints with Tailwind's palette; use the design's tokens, such as bg-muted or text-primary.",
);
rule.invalid("a palette text with an opacity", 'const c = "text-blue-600/80";', 1);
rule.invalid("a palette colour behind a variant", "const c = `rounded ${on ? 'x' : ''} dark:border-red-500`;", 1);
