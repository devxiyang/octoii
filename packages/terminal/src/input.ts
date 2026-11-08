/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: the keyboard, the input method and the clipboard as one listener on the hidden textarea, the copy and
 * paste shortcuts left to the browser's own clipboard events.
 */
import { keyboardLayout, keyInput, type KeyboardLayout } from "./keys.ts";
import type { VtTerminal } from "./terminal.ts";

/** What the input reaches: the terminal, the program, and the surface's view of history. */
export interface InputHost {
	readonly terminal: VtTerminal;
	/** Sends typed input to the program, which brings the view back to the bottom. */
	readonly type: (data: string) => void;
	/** Scrolls the history by pages, up when negative, or to its top or bottom. */
	readonly scrollPages: (pages: number) => void;
	readonly scrollToEdge: (edge: "top" | "bottom") => void;
	/** Draws again after the selection changed. */
	readonly render: () => void;
}

/** Whether the page runs on Apple's systems, where Command is the shortcut key. */
export const IS_APPLE = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);

/** The keyboard, the input method and the clipboard of the textarea that holds the terminal's focus. */
export class TerminalInput {
	readonly #textarea: HTMLTextAreaElement;
	readonly #host: InputHost;
	readonly #pressed = new Set<string>();
	#layout: KeyboardLayout | undefined;
	#composing = false;
	readonly #abort = new AbortController();

	constructor(textarea: HTMLTextAreaElement, host: InputHost) {
		this.#textarea = textarea;
		this.#host = host;
		void keyboardLayout().then((layout) => (this.#layout = layout));
		const options = { signal: this.#abort.signal };
		textarea.addEventListener("keydown", (event) => this.#keyDown(event), options);
		textarea.addEventListener("keyup", (event) => this.#keyUp(event), options);
		textarea.addEventListener("compositionstart", () => (this.#composing = true), options);
		textarea.addEventListener("compositionend", (event) => this.#compositionEnd(event), options);
		textarea.addEventListener("input", (event) => this.#input(event), options);
		textarea.addEventListener("copy", (event) => this.#copy(event), options);
		textarea.addEventListener("paste", (event) => this.#paste(event), options);
	}

	/** Stops listening. */
	dispose(): void {
		this.#abort.abort();
	}

	#keyDown(event: KeyboardEvent): void {
		// What the input method is composing belongs to the textarea; Safari marks its first key with code 229.
		if (event.isComposing || this.#composing || event.keyCode === 229) return;
		if (event.getModifierState("AltGraph") && [...event.key].length === 1) return;
		if (this.#shortcut(event)) return;
		const data = this.#host.terminal.encodeKey(keyInput(event, "press", this.#layout));
		if (data === "") return;
		this.#pressed.add(event.code);
		event.preventDefault();
		event.stopPropagation();
		this.#host.type(data);
	}

	#keyUp(event: KeyboardEvent): void {
		// A release is reported only for a press the program heard, and only under the Kitty protocol's event types.
		if (!this.#pressed.delete(event.code)) return;
		const data = this.#host.terminal.encodeKey(keyInput(event, "release", this.#layout));
		if (data === "") return;
		event.preventDefault();
		this.#host.type(data);
	}

	/** The surface's own shortcuts: copy, paste, select all, and paging through history. */
	#shortcut(event: KeyboardEvent): boolean {
		const primary = IS_APPLE ? event.metaKey && !event.ctrlKey : event.ctrlKey && event.shiftKey;
		const key = event.key.toLowerCase();
		const { terminal } = this.#host;
		if (primary && key === "c" && terminal.hasSelection()) {
			// A canvas has no selection of the page's: the textarea holds the text, so the browser's copy finds it.
			this.#textarea.value = terminal.selectedText();
			this.#textarea.select();
			return true;
		}
		if (primary && key === "v") return true;
		if (primary && key === "a") {
			event.preventDefault();
			terminal.selectAll();
			this.#host.render();
			return true;
		}
		return this.#historyShortcut(event);
	}

	#historyShortcut(event: KeyboardEvent): boolean {
		if (!event.shiftKey || event.altKey || this.#host.terminal.isAlternateScreen()) return false;
		const jump = IS_APPLE ? event.metaKey : event.ctrlKey;
		if (!jump && !event.metaKey && !event.ctrlKey && (event.key === "PageUp" || event.key === "PageDown")) {
			this.#host.scrollPages(event.key === "PageUp" ? -1 : 1);
		} else if (jump && (event.key === "Home" || event.key === "End")) {
			this.#host.scrollToEdge(event.key === "Home" ? "top" : "bottom");
		} else return false;
		event.preventDefault();
		return true;
	}

	#compositionEnd(event: CompositionEvent): void {
		this.#composing = false;
		const data = event.data || this.#textarea.value;
		this.#textarea.value = "";
		if (data !== "") this.#host.type(data);
	}

	/** Text that came in without a key the encoder took: a dictation, an emoji picker, a mobile keyboard. */
	#input(event: Event): void {
		if (this.#composing || (event instanceof InputEvent && event.isComposing)) return;
		// The text a composition committed was already sent when it ended.
		if (event instanceof InputEvent && event.inputType === "insertFromComposition") {
			this.#textarea.value = "";
			return;
		}
		const data = this.#textarea.value;
		this.#textarea.value = "";
		if (data !== "") this.#host.type(data);
	}

	#copy(event: ClipboardEvent): void {
		const { terminal } = this.#host;
		const text = terminal.hasSelection() ? terminal.selectedText() : "";
		this.#textarea.value = "";
		if (text === "" || event.clipboardData === null) return;
		event.clipboardData.setData("text/plain", text);
		event.preventDefault();
	}

	#paste(event: ClipboardEvent): void {
		// The textarea's own insertion would skip the bracketing the program asked for.
		event.preventDefault();
		const text = event.clipboardData?.getData("text/plain") ?? "";
		if (text !== "") this.#host.type(this.#host.terminal.encodePaste(text));
	}
}
