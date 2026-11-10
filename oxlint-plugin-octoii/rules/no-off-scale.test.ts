import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-off-scale");

rule.valid("the design's type", 'const c = "text-ui text-body leading-tight tracking-caps md:text-xs text-title";');
rule.valid("a colour in brackets", 'const c = "text-[#0a0a0a] text-[var(--ink)] bg-[color-mix(in_srgb,red,blue)]";');
rule.valid("a size outside a class", 'const label = "13px";');
rule.valid("the design's radii", 'const c = "rounded-sm rounded-t-md rounded-lg rounded-full rounded-none rounded-(--thumb-size) rounded-[inherit]";');
rule.valid("the design's shadows", 'const c = "shadow-raised hover:shadow-floating shadow-none";');
rule.valid("a word that only looks like a utility", 'const c = "box-shadow text-smart rounded-smooth";');

rule.invalid(
	"a size of its own",
	'const c = "flex text-[13px]";',
	"text-[13px] sets type off the design's scale; use its sizes and lines, such as text-ui, text-body or tracking-caps.",
);
rule.invalid("a line of its own", 'const c = "font-mono text-xs leading-[1.6]";', 1);
rule.invalid("a spacing of its own behind a variant", "const c = `uppercase ${on ? 'x' : ''} md:tracking-[0.08em]`;", 1);
rule.invalid("a calculated size", 'const c = "text-[calc(1rem-1px)]";', 1);
rule.invalid(
	"one of Tailwind's sizes",
	'const c = "text-sm font-medium";',
	"text-sm is no size of the design's; use text-2xs, text-xs, text-ui, text-body or text-title.",
);
rule.invalid("two of Tailwind's sizes", 'const c = "text-base md:text-2xl";', 2);
rule.invalid(
	"a radius of Tailwind's",
	'const c = "rounded-xl border";',
	"rounded-xl is no radius of the design's; use rounded-sm, rounded-md, rounded-lg or rounded-full.",
);
rule.invalid("the bare radius", 'const c = "rounded px-1";', 1);
rule.invalid("a radius of its own on a side", 'const c = "rounded-b-[20px]";', 1);
rule.invalid("a bare radius on a corner", 'const c = "rounded-tl";', 1);
rule.invalid(
	"a shadow of Tailwind's",
	'const c = "shadow-xs/5";',
	"shadow-xs/5 is no shadow of the design's; use shadow-raised for what stands a little raised, shadow-floating for what floats.",
);
rule.invalid("an inset shadow and a tinted one", 'const c = "inset-shadow-sm shadow-primary/24";', 2);
rule.invalid("a shadow of its own", 'const c = "shadow-[0_1px_2px_black]";', 1);
