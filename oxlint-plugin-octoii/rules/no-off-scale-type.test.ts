import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-off-scale-type");

rule.valid("the design's scale", 'const c = "text-ui text-body leading-tight tracking-caps md:text-sm";');
rule.valid("a colour in brackets", 'const c = "text-[#0a0a0a] text-[var(--ink)] bg-[color-mix(in_srgb,red,blue)]";');
rule.valid("a size outside a class", 'const label = "13px";');

rule.invalid(
	"a size of its own",
	'const c = "flex text-[13px]";',
	"text-[13px] sets type off the design's scale; use its sizes and lines, such as text-ui, text-body or tracking-caps.",
);
rule.invalid("a line of its own", 'const c = "font-mono text-xs leading-[1.6]";', 1);
rule.invalid("a spacing of its own behind a variant", "const c = `uppercase ${on ? 'x' : ''} md:tracking-[0.08em]`;", 1);
rule.invalid("a calculated size", 'const c = "text-[calc(1rem-1px)]";', 1);
