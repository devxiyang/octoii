import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-reduce-accumulator-copy");
const MESSAGE =
	"Do not copy the reducer accumulator on every iteration; growing copies can cause quadratic work. Mutate a fresh, locally owned accumulator and return it, or use an iterator pipeline/flatMap.";

rule.valid("a push onto the accumulator", "items.reduce((acc, item) => { acc.push(item); return acc; }, []);");
rule.valid("an Object.assign into the accumulator", "items.reduce((acc, item) => Object.assign(acc, item), {});");
rule.valid("an Object.assign into the accumulator from itself", "items.reduce((acc, item) => Object.assign(acc, acc, item), {});");
rule.valid("a copy of the item, not the accumulator", "items.reduce((acc, item) => { acc[item.id] = { ...item }; return acc; }, {});");
rule.valid("an Object.assign copy of the item", "items.reduce((acc, item) => { acc.push(Object.assign({}, item)); return acc; }, []);");
rule.valid("a slice of the item", "items.reduce((acc, item) => { acc.push(item.slice()); return acc; }, []);");
rule.valid("a concat onto a string accumulator", "items.reduce((acc, item) => acc.concat(item), '');");
rule.valid("a concat onto an accumulator not known to be an array", "items.reduce((acc, item) => acc.concat(item), customCollection);");
rule.valid("a copy outside any reducer", "function copy(acc) { return Object.assign({}, acc); }");
rule.valid("a copy in a map callback", "items.map((acc, item) => Object.assign({}, acc));");
rule.valid(
	"a copy in a function declared inside the reducer",
	"items.reduce((acc, item) => { function copy(acc) { return Object.assign({}, acc); } return acc; }, {});",
);
rule.valid("a copy in a closure inside the reducer", "items.reduce((acc, item) => { const snapshot = () => Object.assign({}, acc); return acc; }, {});");
rule.valid("a copy of a shadowing binding", "items.reduce((acc, item) => { { const acc = {}; Object.assign({}, acc); } return acc; }, {});");
rule.valid("an Object.assign of a local Object", "const Object = custom; items.reduce((acc, item) => Object.assign({}, acc), {});");
rule.valid("an Object.assign of a parameter named Object", "function run(Object) { return items.reduce((acc, item) => Object.assign({}, acc), {}); }");
rule.valid("an Array.from of a local Array", "const Array = custom; items.reduce((acc, item) => Array.from(acc), []);");
rule.valid("a copy of a reassigned alias", "items.reduce((acc, item) => { let alias = acc; alias = item; return Object.assign({}, alias); }, {});");
// The spread form is `oxc/no-accumulating-spread`'s.
rule.valid("an array spread of the accumulator", "items.reduce((acc, item) => [...acc, item], []);");
rule.valid("an object spread of the accumulator", "items.reduce((acc, item) => ({ ...acc, [item.id]: item }), {});");

rule.invalid("an Object.assign copy of the accumulator", "items.reduce((acc, item) => Object.assign({}, acc, { [item.id]: item }), {});", MESSAGE);
rule.invalid("a copy in reduceRight", "items.reduceRight((acc, item) => Object.assign({}, acc, item), {});", MESSAGE);
rule.invalid("a copy in a reducer with every parameter", "items.reduce((acc, item, index, array) => Object.assign({}, acc, item), {});", MESSAGE);
rule.invalid("a copy in a reducer with one parameter", "items.reduce(acc => Object.assign({}, acc), {});", MESSAGE);
rule.invalid("a copy in a function expression", "items.reduce(function (acc, item) { return Object.assign({}, item, acc); }, {});", MESSAGE);
rule.invalid("computed member names", "items['reduce'](((acc, item) => Object['assign']({}, acc, item)), {});", MESSAGE);
rule.invalid("an accumulator with a default", "items.reduce((acc = {}, item) => Object.assign({}, acc, item), {});", MESSAGE);
rule.invalid("a copy of a const alias", "items.reduce((acc, item) => { const alias = acc; return Object.assign({}, alias, item); }, {});", MESSAGE);
rule.invalid("a copy of an asserted accumulator", "items.reduce((acc, item) => Object.assign({}, acc as State, item), {});", MESSAGE);
rule.invalid(
	"a copy kept in a local",
	"items.reduce((acc, item) => { const next = Object.assign({}, acc); next[item.id] = item; return next; }, {});",
	MESSAGE,
);
rule.invalid("a concat onto an array accumulator", "items.reduce((acc, item) => acc.concat([item]), []);", MESSAGE);
rule.invalid("a computed concat onto an asserted array", "items.reduceRight((acc, item, index) => acc['concat']([item]), [] as Item[]);", MESSAGE);
rule.invalid("a slice of the accumulator", "items.reduce((acc, item) => { const next = acc.slice(); next.push(item); return next; }, []);", MESSAGE);
rule.invalid("a concat onto a const alias", "items.reduce((acc, item) => { const alias = acc; return alias.concat(item); }, []);", MESSAGE);
rule.invalid("an initial value held in a const", "const initial = []; items.reduce((acc, item) => acc.concat(item), initial);", MESSAGE);
rule.invalid("an Array.from copy", "items.reduce((acc, item) => { const next = Array.from(acc); next.push(item); return next; }, []);", MESSAGE);
rule.invalid("a toSpliced copy", "items.reduce((acc, item) => acc.toSpliced(acc.length, 0, item), []);", MESSAGE);
rule.invalid("a toSorted copy", "items.reduce((acc, item) => acc.toSorted(), []);", MESSAGE);
rule.invalid("a toReversed copy", "items.reduce((acc, item) => acc.toReversed(), []);", MESSAGE);
rule.invalid("a with copy", "items.reduce((acc, item) => acc.with(0, item), []);", MESSAGE);
