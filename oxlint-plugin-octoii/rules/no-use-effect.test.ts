import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-use-effect");

const MESSAGE = (name: string): string =>
	`No ${name} here: compute in render, act in the event handler, reset with a key, or wrap the outside system in a named hook under effects/.`;

rule.valid("a value computed in render", "const total = items.length * 2;");
rule.valid("an effect in a hook of an effects folder", "import { useEffect } from 'react';\nuseEffect(() => {}, []);", "src/effects/window-size.ts");
rule.valid("a function of another name", "useEffectEvent(() => {});");

rule.invalid("a useEffect", "import { useEffect } from 'react';\nuseEffect(() => {}, []);", MESSAGE("useEffect"));
rule.invalid("a useLayoutEffect", "useLayoutEffect(() => {});", MESSAGE("useLayoutEffect"));
rule.invalid("an effect read from React's namespace", "React.useEffect(() => {});", MESSAGE("useEffect"));
rule.invalid("an effect in a file named effects", "useEffect(() => {});", 1, "src/effects.ts");
