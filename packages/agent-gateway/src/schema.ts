/** TypeBox validators, compiled once per schema, by which what comes from outside is read at the gateway's edge. */
import type { Static, TSchema } from "typebox";
import { Compile, type Validator } from "typebox/compile";

const validators = new WeakMap<TSchema, Validator>();

function compiled<Schema extends TSchema>(schema: Schema): Validator<{}, Schema> {
	const cached = validators.get(schema);
	if (cached !== undefined) return retyped(schema, cached);
	const validator = Compile(schema);
	validators.set(schema, validator);
	return validator;
}

/** Whether `value` is of the type of `schema`. */
export function matches<Schema extends TSchema>(schema: Schema, value: unknown): value is Static<Schema> {
	return compiled(schema).Check(value);
}

/** Why `value` is not of the type of `schema`, a line per problem: where, and what is wrong; none where it is. */
export function problemsOf(schema: TSchema, value: unknown): readonly string[] {
	const validator = compiled(schema);
	if (validator.Check(value)) return [];
	return [...validator.Errors(value)].map((error) => `${error.instancePath || "/"} ${error.message}`);
}

/** The validator cached for `schema`, as the type it was compiled with. */
function retyped<Schema extends TSchema>(_schema: Schema, validator: Validator): Validator<{}, Schema> {
	// SAFETY: the cache is keyed by the schema object itself, so the validator was compiled from this very schema.
	return validator as Validator<{}, Schema>;
}
