import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-off-token-colors");

rule.valid("the design's tokens", 'const c = "bg-muted text-primary border-border hover:bg-accent text-faint-foreground";');
rule.valid("white and black ink", 'const c = "bg-black text-white";');
rule.valid("a word that only looks like a hue", 'const c = "text-ui text-balance bg-blueprint";');
rule.valid("a hue outside a class", 'const label = "Blue 500";');
rule.valid("a slash that is no opacity", 'const c = "w-1/2 text-ui/5 group-hover/row:bg-accent aspect-4/3";');
rule.valid("the word dark outside a class", 'const label = "Whether the page shows dark: the device says";');

rule.invalid(
	"a palette background",
	'const c = "flex bg-zinc-100";',
	"bg-zinc-100 paints with Tailwind's palette; use the design's tokens, such as bg-muted or text-primary.",
);
rule.invalid("a palette colour behind a variant", "const c = `flex ${on ? 'x' : ''} hover:border-red-500`;", 1);
rule.invalid(
	"a token thinned",
	'const c = "border border-border/60";',
	"border-border/60 thins a colour to one of its own; use the token that is that step, such as text-faint-foreground, border-border or bg-accent.",
);
rule.invalid("two tokens thinned", 'const c = "text-muted-foreground/70 hover:bg-accent/50";', 2);
rule.invalid("black thinned by a value of its own", 'const c = "border-black/[0.08]";', 1);
rule.invalid(
	"a utility for the dark scheme",
	'const c = "bg-popover dark:bg-input";',
	"dark:bg-input paints one scheme apart; a scheme changes the tokens, so the utility that reads a token is right in both.",
);
