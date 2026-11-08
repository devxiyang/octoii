/**
 * TypeBox validators, compiled once per schema. Compiling generates code to check values fast; on a platform without
 * generated code, or one that refuses it while it handles a request as workerd does, every validator from then on
 * checks values by walking the schema, with the same results.
 */
import type { Static, TSchema } from "typebox";
import { Compile, type Validator } from "typebox/compile";
import { Settings } from "typebox/system";

export type { Validator } from "typebox/compile";

const validators = new WeakMap<TSchema, Validator>();

/** The validator of `schema`, compiled on first use and cached by the schema object. */
export function compiled<Schema extends TSchema>(schema: Schema): Validator<{}, Schema> {
	const cached = validators.get(schema);
	if (cached !== undefined) return retypedValidator(schema, cached);
	const validator = compileOnThisPlatform(schema);
	validators.set(schema, validator);
	return validator;
}

/** A value that fails its schema: what it was meant to be, and each problem with its place. */
export class InvalidValueError extends Error {
	readonly problems: readonly string[];

	constructor(what: string, problems: readonly string[]) {
		super(`Invalid ${what}: ${problems.join("; ")}`);
		this.name = "InvalidValueError";
		this.problems = problems;
	}
}

/** Whether `value` is of the type of `schema`. */
export function matches<Schema extends TSchema>(schema: Schema, value: unknown): value is Static<Schema> {
	return compiled(schema).Check(value);
}

/** `value` as the type of `schema`; throws `InvalidValueError` naming `what` and each problem where it fails. */
export function parsed<Schema extends TSchema>(schema: Schema, value: unknown, what: string): Static<Schema> {
	const validator = compiled(schema);
	if (validator.Check(value)) return value;
	throw new InvalidValueError(what, validationProblems(validator, value));
}

/** Why `value` fails `validator`, one line per problem: where, and what is wrong. */
export function validationProblems(validator: Validator, value: unknown): string[] {
	return [...validator.Errors(value)].map((error) => `${error.instancePath || "/"} ${error.message}`);
}

/**
 * TypeBox probes once whether it may generate code and walks the schema where it may not, as on Hermes. A platform that
 * allowed the probe but refuses later code, as workerd does while it handles a request, throws an `EvalError`: from then
 * on every validator walks the schema.
 */
function compileOnThisPlatform<Schema extends TSchema>(schema: Schema): Validator<{}, Schema> {
	try {
		return Compile(schema);
	} catch (error) {
		if (!(error instanceof EvalError)) throw error;
		Settings.Set({ useAcceleration: false });
		return Compile(schema);
	}
}

/** A cached validator, typed again by the schema it was compiled from: the cache is keyed by that schema. */
function retypedValidator<Schema extends TSchema>(_schema: Schema, validator: Validator): Validator<{}, Schema> {
	// SAFETY: the cache is keyed by the schema, so the validator was compiled from this very schema.
	return validator as Validator<{}, Schema>;
}
