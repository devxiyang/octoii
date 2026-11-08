/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: written for the newest libghostty-vt ABI, whose layouts and enum values all come from the module's own
 * manifest; handles made by one function; one table of callbacks routed to each terminal.
 */
import { parsed } from "./std/schema.ts";
import { Type } from "typebox";

const FieldSchema = Type.Object({ offset: Type.Number(), size: Type.Number(), type: Type.String() });

const TypeSchema = Type.Object({
	kind: Type.String(),
	size: Type.Optional(Type.Number()),
	type: Type.Optional(Type.String()),
	underlying: Type.Optional(Type.String()),
	fields: Type.Optional(Type.Record(Type.String(), FieldSchema)),
	values: Type.Optional(Type.Record(Type.String(), Type.Number())),
});

/** The manifest libghostty-vt describes its ABI with: each type's size, fields and, for an enum, its values. */
const ManifestSchema = Type.Object({ types: Type.Record(Type.String(), TypeSchema) });

type TypeEntry = Type.Static<typeof TypeSchema>;
type Field = Type.Static<typeof FieldSchema>;

/** What a terminal hears from the module while it writes: a hold of the screen. */
export interface TerminalCallbacks {
	readonly renderHold: (held: boolean) => void;
}

/** The function-table slots of the callbacks, set on a terminal as its options' values. */
export interface CallbackSlots {
	readonly renderHold: number;
}

/** A call into the module that did not succeed, named for the call and the result. */
export class GhosttyCallFailed extends Error {
	readonly call: string;
	readonly result: string;

	constructor(call: string, result: string) {
		super(`${call} failed: ${result}`);
		this.call = call;
		this.result = result;
	}
}

type WasmFunction = (...args: (number | bigint)[]) => number;

/** The output buffer's first size: an encoded key, a report or a link fits; a selection grows it. */
const OUTPUT_BYTES = 256;

const decoder = new TextDecoder();

/** libghostty-vt's WebAssembly module: its memory, its manifest, its calls, and the callbacks in its function table. */
export class Ghostty {
	readonly #exports: WebAssembly.Exports;
	readonly #memory: WebAssembly.Memory;
	readonly #types: Readonly<Record<string, TypeEntry>>;
	readonly #routes = new Map<number, TerminalCallbacks>();
	readonly #resultNames: ReadonlyMap<number, string>;
	#bytes: Uint8Array;
	#view: DataView;
	#nextRoute = 1;
	#output = { pointer: 0, capacity: 0, written: 0 };
	/** The callbacks' slots in the module's function table. */
	readonly callbacks: CallbackSlots;

	private constructor(vt: WebAssembly.Instance, callbacks: WebAssembly.Module) {
		this.#exports = vt.exports;
		const memory = vt.exports["memory"];
		if (!(memory instanceof WebAssembly.Memory)) throw new Error("libghostty-vt exports no memory");
		this.#memory = memory;
		this.#bytes = new Uint8Array(memory.buffer);
		this.#view = new DataView(memory.buffer);
		this.#types = parsed(ManifestSchema, JSON.parse(this.cString(this.call("ghostty_type_json"))), "libghostty-vt's manifest").types;
		this.#resultNames = new Map(Object.entries(this.enumValues("GhosttyResult")).map(([name, value]) => [value, name]));
		this.callbacks = this.#installCallbacks(new WebAssembly.Instance(callbacks, { env: this.#callbackImports() }));
	}

	/** Instantiates the module and its callbacks from their compiled bytes or their responses. */
	static async instantiate(vt: WasmSource, callbacks: WasmSource): Promise<Ghostty> {
		const [vtModule, callbacksModule] = await Promise.all([compiled(vt), compiled(callbacks)]);
		return new Ghostty(await WebAssembly.instantiate(vtModule, {}), callbacksModule);
	}

	/** Calls an export of the module. */
	call(name: string, ...args: (number | bigint)[]): number {
		return this.fn(name)(...args);
	}

	/** Calls an export and throws unless it succeeds. */
	check(name: string, ...args: (number | bigint)[]): void {
		const result = this.call(name, ...args);
		if (result !== 0) throw new GhosttyCallFailed(name, this.resultName(result));
	}

	/** An export of the module, to call in a loop without looking it up each time. */
	fn(name: string): WasmFunction {
		const fn = this.#exports[name];
		if (typeof fn !== "function") throw new Error(`libghostty-vt has no export ${name}`);
		// SAFETY: every function the module exports takes integers and returns an integer or nothing.
		return fn as WasmFunction;
	}

	/** A result's name, as the manifest's GhosttyResult has it. */
	resultName(result: number): string {
		return this.#resultNames.get(result) ?? String(result);
	}

	/** An enum's values by name, as the manifest has them. */
	enumValues(name: string): Readonly<Record<string, number>> {
		const values = this.#type(name).values;
		if (values === undefined) throw new Error(`libghostty-vt's ${name} is no enum`);
		return values;
	}

	/** The named values of an enum, each looked up once: a missing name is an ABI the code does not know. */
	values<const Names extends readonly string[]>(name: string, names: Names): Readonly<Record<Names[number], number>> {
		const values = this.enumValues(name);
		const found = new Map<string, number>();
		for (const key of names) {
			const value = values[key];
			if (value === undefined) throw new Error(`libghostty-vt's ${name} has no ${key}`);
			found.set(key, value);
		}
		// SAFETY: the map holds every name, or the loop threw.
		return Object.fromEntries(found) as Record<Names[number], number>;
	}

	/** A type's size in bytes. */
	sizeOf(name: string): number {
		const size = this.#type(name).size;
		if (size === undefined) throw new Error(`libghostty-vt's ${name} has no size`);
		return size;
	}

	/** Whether a struct has a field. */
	hasField(type: string, name: string): boolean {
		return this.#type(type).fields?.[name] !== undefined;
	}

	/** A field of a struct. */
	field(type: string, name: string): Field {
		const field = this.#type(type).fields?.[name];
		if (field === undefined) throw new Error(`libghostty-vt's ${type} has no field ${name}`);
		return field;
	}

	/** Allocates zeroed bytes in the module's memory. */
	alloc(size: number): number {
		const pointer = this.call("ghostty_wasm_alloc", size);
		if (pointer === 0) throw new Error(`libghostty-vt could not allocate ${size} bytes`);
		this.bytes().fill(0, pointer, pointer + size);
		return pointer;
	}

	/** Frees bytes from alloc. */
	free(pointer: number, size: number): void {
		if (pointer !== 0) this.call("ghostty_wasm_free", pointer, size);
	}

	/** A new struct, zeroed, its `size` set when it is a sized struct. */
	struct(type: string): Struct {
		const size = this.sizeOf(type);
		const struct = new Struct(this, type, this.alloc(size), size);
		if (this.hasField(type, "size")) struct.set("size", size);
		return struct;
	}

	/** A handle made by `make(allocator, &handle, ...args)`, the shape of every constructor of the ABI. */
	handle(make: string, ...args: number[]): number {
		const slot = this.call("ghostty_wasm_alloc_opaque");
		try {
			this.view().setUint32(slot, 0, true);
			this.check(make, 0, slot, ...args);
			return this.call("ghostty_wasm_take_opaque", slot);
		} finally {
			this.call("ghostty_wasm_free_opaque", slot);
		}
	}

	/**
	 * The text a call writes into a buffer, `call(buffer, capacity, written)`: asked again in a buffer of the size it
	 * reports when the first is too small, undefined when it has no value.
	 */
	output(name: string, call: (buffer: number, capacity: number, written: number) => number): string | undefined {
		if (this.#output.written === 0) this.#output = { pointer: this.alloc(OUTPUT_BYTES), capacity: OUTPUT_BYTES, written: this.alloc(4) };
		let result = call(this.#output.pointer, this.#output.capacity, this.#output.written);
		if (result === this.#result("OUT_OF_SPACE")) {
			const needed = this.view().getUint32(this.#output.written, true);
			this.free(this.#output.pointer, this.#output.capacity);
			this.#output = { ...this.#output, pointer: this.alloc(needed), capacity: needed };
			result = call(this.#output.pointer, this.#output.capacity, this.#output.written);
		}
		if (result === this.#result("NO_VALUE")) return undefined;
		if (result !== 0) throw new GhosttyCallFailed(name, this.resultName(result));
		return this.text(this.#output.pointer, this.view().getUint32(this.#output.written, true));
	}

	/** Writes bytes into new memory, which the caller frees with `free(pointer, bytes.length)`. */
	copyIn(bytes: Uint8Array): number {
		const pointer = this.alloc(Math.max(1, bytes.length));
		this.bytes().set(bytes, pointer);
		return pointer;
	}

	/** Text of UTF-8 bytes in the module's memory. */
	text(pointer: number, length: number): string {
		return decoder.decode(this.bytes().subarray(pointer, pointer + length));
	}

	/** Text of a zero-terminated string in the module's memory. */
	cString(pointer: number): string {
		const bytes = this.bytes();
		const end = bytes.indexOf(0, pointer);
		return decoder.decode(bytes.subarray(pointer, end === -1 ? bytes.length : end));
	}

	/** The module's memory as bytes, current after the memory grows. */
	bytes(): Uint8Array {
		this.#refresh();
		return this.#bytes;
	}

	/** The module's memory as a view, current after the memory grows. */
	view(): DataView {
		this.#refresh();
		return this.#view;
	}

	/** Routes the callbacks a terminal's userdata names to its handlers; the returned id is that userdata. */
	route(callbacks: TerminalCallbacks): number {
		const id = this.#nextRoute++;
		this.#routes.set(id, callbacks);
		return id;
	}

	/** Stops routing a terminal's callbacks. */
	unroute(id: number): void {
		this.#routes.delete(id);
	}

	#refresh(): void {
		// Growing the memory detaches the old buffer, whose views then read as empty.
		if (this.#bytes.byteLength > 0) return;
		this.#bytes = new Uint8Array(this.#memory.buffer);
		this.#view = new DataView(this.#memory.buffer);
	}

	#result(name: string): number {
		const value = this.enumValues("GhosttyResult")[name];
		if (value === undefined) throw new Error(`libghostty-vt has no result ${name}`);
		return value;
	}

	#type(name: string): TypeEntry {
		const entry = this.#types[name];
		if (entry === undefined) throw new Error(`libghostty-vt has no type ${name}`);
		return entry;
	}

	#callbackImports(): WebAssembly.ModuleImports {
		return {
			render_hold: (_terminal: number, route: number, held: number) => this.#routes.get(route)?.renderHold(held !== 0),
		};
	}

	#installCallbacks(callbacks: WebAssembly.Instance): CallbackSlots {
		const table = this.#exports["__indirect_function_table"];
		if (!(table instanceof WebAssembly.Table)) throw new Error("libghostty-vt exports no function table");
		const install = (name: string): number => {
			const fn = callbacks.exports[name];
			if (typeof fn !== "function") throw new Error(`the callbacks module has no ${name}`);
			const slot = table.length;
			// WebKit's grow(1, fn) keeps a broken signature that traps when called; set() stores it whole.
			table.grow(1);
			table.set(slot, fn);
			return slot;
		};
		return { renderHold: install("on_render_hold") };
	}
}

/** A module's compiled bytes, or the response that brings them. */
export type WasmSource = BufferSource | Response | PromiseLike<Response>;

async function compiled(source: WasmSource): Promise<WebAssembly.Module> {
	if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) return WebAssembly.compile(source);
	const response = await source;
	if (!response.ok) throw new Error(`libghostty-vt did not load (${response.status})`);
	return WebAssembly.compileStreaming(response);
}

/** A struct in the module's memory, its fields read and written by name. */
export class Struct {
	readonly ghostty: Ghostty;
	readonly type: string;
	readonly pointer: number;
	readonly size: number;

	constructor(ghostty: Ghostty, type: string, pointer: number, size: number) {
		this.ghostty = ghostty;
		this.type = type;
		this.pointer = pointer;
		this.size = size;
	}

	/** The address of a field, for a call that takes it or a nested struct. */
	at(name: string): number {
		return this.pointer + this.ghostty.field(this.type, name).offset;
	}

	/** Writes a number field. */
	set(name: string, value: number): this {
		const field = this.ghostty.field(this.type, name);
		writeNumber(this.ghostty.view(), this.pointer + field.offset, field, value);
		return this;
	}

	/** Reads a number field. */
	get(name: string): number {
		const field = this.ghostty.field(this.type, name);
		return readNumber(this.ghostty.view(), this.pointer + field.offset, field);
	}

	/** Copies a field's bytes in from another address, as a nested struct is set. */
	copy(name: string, from: number): this {
		const field = this.ghostty.field(this.type, name);
		const bytes = this.ghostty.bytes();
		bytes.copyWithin(this.pointer + field.offset, from, from + field.size);
		return this;
	}

	/** Zeroes the struct, keeping its `size` when it has one. */
	clear(): this {
		this.ghostty.bytes().fill(0, this.pointer, this.pointer + this.size);
		if (this.ghostty.hasField(this.type, "size")) this.set("size", this.size);
		return this;
	}

	/** Frees the struct. */
	free(): void {
		this.ghostty.free(this.pointer, this.size);
	}
}

function writeNumber(view: DataView, offset: number, field: Field, value: number): void {
	switch (scalar(field)) {
		case "u8":
		case "i8":
			view.setUint8(offset, value);
			return;
		case "u16":
			view.setUint16(offset, value, true);
			return;
		case "i32":
			view.setInt32(offset, value, true);
			return;
		case "u32":
			view.setUint32(offset, value, true);
			return;
		case "u64":
			view.setBigUint64(offset, BigInt(value), true);
			return;
		case "f32":
			view.setFloat32(offset, value, true);
			return;
		case "f64":
			view.setFloat64(offset, value, true);
	}
}

function readNumber(view: DataView, offset: number, field: Field): number {
	switch (scalar(field)) {
		case "u8":
			return view.getUint8(offset);
		case "i8":
			return view.getInt8(offset);
		case "u16":
			return view.getUint16(offset, true);
		case "i32":
			return view.getInt32(offset, true);
		case "u32":
			return view.getUint32(offset, true);
		case "u64":
			return Number(view.getBigUint64(offset, true));
		case "f32":
			return view.getFloat32(offset, true);
		case "f64":
			return view.getFloat64(offset, true);
	}
}

type Scalar = "u8" | "i8" | "u16" | "i32" | "u32" | "u64" | "f32" | "f64";

/** A field's number type: a bool is a byte, a pointer a u32 in wasm32, an enum its i32, by its size otherwise. */
function scalar(field: Field): Scalar {
	switch (field.type) {
		case "bool":
		case "u8":
			return "u8";
		case "i8":
		case "u16":
		case "i32":
		case "u32":
		case "u64":
		case "f32":
		case "f64":
			return field.type;
		case "pointer":
			return "u32";
	}
	if (field.size === 4) return "i32";
	if (field.size === 2) return "u16";
	if (field.size === 1) return "u8";
	throw new Error(`a ${field.type} field is no number`);
}
