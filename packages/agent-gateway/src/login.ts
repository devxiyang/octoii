/**
 * Signing an agent in: the program that does it, for the account the gateway answers for — its arguments, the first
 * the program, and what its environment holds beside the person's — which the host runs in a terminal for the person.
 */

/** A variable a program's environment holds. */
export type Variable = { readonly name: string; readonly value: string };

/** The program that signs an agent in. */
export type Login = { readonly argv: readonly string[]; readonly environment: readonly Variable[] };
