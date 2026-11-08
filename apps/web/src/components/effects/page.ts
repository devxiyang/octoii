/**
 * A page of the browser drawn in an element, as a VNC viewer draws a framebuffer: followed in a view the size of the
 * element's room once it has one, told again as the room settles at another; each frame the node sends drawn on a
 * canvas at the page's CSS size, the newest alone where frames come faster than they are decoded. The person's mouse
 * over it and their keys while it is focused are sent to the page — a drag held to it past its edge, a move sent once
 * a frame, a key the app answers as its shortcut kept from it, as a window's menu takes its shortcuts before the view
 * focused does — and the text they paste, compose with an input method, or put in by no key of its own, sent as
 * text, through a field of its own that takes the focus as the page is shown, where the person types in no field, as
 * a terminal's hidden field does.
 */
import { useCallback } from "react";
import type { PageFrame, PageMouse, PageSize, PageView } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { editingOf, modifiersOf, typedBy } from "../../core/browser.ts";
import { isTypedIn } from "./shortcut.ts";

/** How long the room stands at a size before the page is laid out at it. */
const SETTLE_MS = 120;

/** The pixels a wheel's line turns, where it counts in lines. */
const LINE_PIXELS = 16;

/** The ref that mounts the page `page` in the element it is given, and takes it out as the element goes. */
export function usePageView(page: string): (element: HTMLDivElement | null) => (() => void) | undefined {
	const client = useClient();
	return useCallback(
		(element: HTMLDivElement | null) => {
			if (element === null) return undefined;
			const surface = mountSurface(element);
			let view: PageView | undefined;
			let settling: ReturnType<typeof setTimeout> | undefined;
			const settled = (): void => {
				const size = sizeOf(element);
				if (size === undefined) return;
				if (view === undefined) view = client.page(page, size, { frame: surface.draw });
				else view.resize(size);
			};
			const observer = new ResizeObserver(() => {
				clearTimeout(settling);
				settling = setTimeout(settled, view === undefined ? 0 : SETTLE_MS);
			});
			observer.observe(element);
			const stopInput = takeInput(element, surface, (send) => view !== undefined && send(view));
			// A page opened takes the focus from anything else, never from a field the person types in.
			if (!isTypedIn(document.activeElement)) surface.field.focus({ preventScroll: true });
			return () => {
				clearTimeout(settling);
				observer.disconnect();
				stopInput();
				view?.stop();
				surface.remove();
			};
		},
		[client, page],
	);
}

/** The size of `element`'s room as a page's view, none while it has no room. */
function sizeOf(element: HTMLElement): PageSize | undefined {
	const width = Math.floor(element.clientWidth);
	const height = Math.floor(element.clientHeight);
	if (width === 0 || height === 0) return undefined;
	return { width, height, scale: window.devicePixelRatio };
}

/** What a page is drawn on: its canvas, the field that takes its keys, drawing a frame, and taking them out again. */
type Surface = {
	readonly canvas: HTMLCanvasElement;
	readonly field: HTMLTextAreaElement;
	/** Where a point of the page's CSS pixels is, from a point of the window's. */
	pointOf(clientX: number, clientY: number): { readonly x: number; readonly y: number };
	draw(frame: PageFrame): void;
	remove(): void;
};

/** A canvas and a field put in `element`: frames drawn on the canvas, the newest where they come faster than they are decoded. */
function mountSurface(element: HTMLElement): Surface {
	const canvas = document.createElement("canvas");
	canvas.className = "absolute top-0 left-0 bg-white";
	const field = document.createElement("textarea");
	field.className = "absolute top-0 left-0 size-px resize-none opacity-0";
	field.setAttribute("aria-label", "The page");
	field.autocapitalize = "off";
	field.spellcheck = false;
	element.append(canvas, field);
	const context = canvas.getContext("2d");
	let next: PageFrame | undefined;
	let drawing = false;
	let shown = { width: 0, height: 0 };
	const drawNext = async (): Promise<void> => {
		drawing = true;
		for (let frame = next; frame !== undefined; frame = next) {
			next = undefined;
			const image = await createImageBitmap(new Blob([bytesOf(frame.data)], { type: "image/jpeg" })).catch(() => undefined);
			if (image === undefined) continue;
			if (canvas.width !== image.width || canvas.height !== image.height) Object.assign(canvas, { width: image.width, height: image.height });
			if (shown.width !== frame.width || shown.height !== frame.height) {
				shown = { width: frame.width, height: frame.height };
				Object.assign(canvas.style, { width: `${String(frame.width)}px`, height: `${String(frame.height)}px` });
			}
			context?.drawImage(image, 0, 0);
			image.close();
		}
		drawing = false;
	};
	return {
		canvas,
		field,
		pointOf: (clientX, clientY) => {
			const box = canvas.getBoundingClientRect();
			const across = box.width === 0 ? 1 : shown.width / box.width;
			const down = box.height === 0 ? 1 : shown.height / box.height;
			return { x: (clientX - box.left) * across, y: (clientY - box.top) * down };
		},
		draw: (frame) => {
			next = frame;
			if (!drawing) void drawNext();
		},
		remove: () => {
			canvas.remove();
			field.remove();
		},
	};
}

/** The bytes base64 writes. */
function bytesOf(base64: string): Uint8Array<ArrayBuffer> {
	const text = atob(base64);
	const bytes = new Uint8Array(text.length);
	for (let at = 0; at < text.length; at += 1) bytes[at] = text.charCodeAt(at);
	return bytes;
}

/** A mouse's button, as the browser's protocol names it. */
type Button = NonNullable<PageMouse["button"]>;

/** The DOM's buttons, by their number, as the browser's protocol names them. */
const BUTTONS: readonly Button[] = ["left", "middle", "right"];

/**
 * Sends the person's mouse over `element` and their keys in its field to the page, through `send`, which reaches the
 * page's view where it is followed; what stops it.
 */
function takeInput(element: HTMLElement, surface: Surface, send: (sending: (view: PageView) => void) => void): () => void {
	const { field } = surface;
	const listening = new AbortController();
	const on = { signal: listening.signal, passive: false };
	const mouse = (event: MouseEvent, type: PageMouse["type"], button: Button, clicks: number): void => {
		const point = surface.pointOf(event.clientX, event.clientY);
		send((view) => view.mouse({ type, ...point, button, buttons: event.buttons, clicks, modifiers: modifiersOf(event) }));
	};
	let moved: MouseEvent | undefined;
	let frame = 0;
	element.addEventListener("pointerdown", (event) => element.setPointerCapture(event.pointerId), on);
	element.addEventListener(
		"mousedown",
		(event) => {
			event.preventDefault();
			field.focus({ preventScroll: true });
			mouse(event, "down", BUTTONS[event.button] ?? "none", event.detail);
		},
		on,
	);
	element.addEventListener("mouseup", (event) => mouse(event, "up", BUTTONS[event.button] ?? "none", event.detail), on);
	element.addEventListener(
		"mousemove",
		(event) => {
			moved = event;
			frame ||= requestAnimationFrame(() => {
				frame = 0;
				if (moved !== undefined) mouse(moved, "move", heldOf(moved.buttons), 0);
			});
		},
		on,
	);
	element.addEventListener(
		"wheel",
		(event) => {
			event.preventDefault();
			const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? LINE_PIXELS : 1;
			const point = surface.pointOf(event.clientX, event.clientY);
			send((view) => view.mouse({ type: "wheel", ...point, delta_x: event.deltaX * unit, delta_y: event.deltaY * unit, modifiers: modifiersOf(event) }));
		},
		on,
	);
	element.addEventListener("contextmenu", (event) => event.preventDefault(), on);
	// A key pressed is heard once the window's own listeners heard it, so a shortcut of the app's, which they take, is passed over.
	window.addEventListener(
		"keydown",
		(event) => {
			if (event.target !== field || event.defaultPrevented || event.isComposing || event.keyCode === 229 || isPaste(event)) return;
			event.preventDefault();
			const text = event.ctrlKey || event.metaKey ? undefined : typedBy(event.key);
			const commands = editingOf(event);
			const pressed = { type: "down", key: event.key, code: event.code, modifiers: modifiersOf(event), key_code: event.keyCode } as const;
			send((view) => view.key({ ...pressed, ...(text === undefined ? {} : { text }), ...(commands === undefined ? {} : { commands: [...commands] }) }));
		},
		on,
	);
	field.addEventListener(
		"keyup",
		(event) => {
			if (event.isComposing || event.keyCode === 229) return;
			send((view) => view.key({ type: "up", key: event.key, code: event.code, modifiers: modifiersOf(event), key_code: event.keyCode }));
		},
		on,
	);
	field.addEventListener(
		"compositionend",
		(event) => {
			field.value = "";
			if (event.data !== "") send((view) => view.text(event.data));
		},
		on,
	);
	// Text put in by no key of its own — dictation, an emoji chosen, a word replaced — is sent as it is.
	field.addEventListener(
		"input",
		(event) => {
			if (event instanceof InputEvent && event.isComposing) return;
			const text = field.value;
			field.value = "";
			if (text !== "") send((view) => view.text(text));
		},
		on,
	);
	field.addEventListener(
		"paste",
		(event) => {
			event.preventDefault();
			const text = event.clipboardData?.getData("text/plain") ?? "";
			if (text !== "") send((view) => view.text(text));
		},
		on,
	);
	return () => {
		cancelAnimationFrame(frame);
		listening.abort();
	};
}

/** The button a move holds, as the browser's protocol names it: the first of those the DOM counts held, left, middle then right. */
function heldOf(buttons: number): Button {
	if (buttons & 1) return "left";
	if (buttons & 4) return "middle";
	if (buttons & 2) return "right";
	return "none";
}

/** Whether a key pressed pastes: ⌘V, or Ctrl+V off a Mac — left to the field, whose paste is sent as text. */
function isPaste(event: KeyboardEvent): boolean {
	return (event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "v";
}
