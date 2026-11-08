/**
 * What the person set for this device, and how it is set: the node's settings for the device's session, as the client
 * last heard them, with the changes made here laid over them till the node tells of them; before it first does, the
 * browser's copy of what it told last, so the page shows as it was set from its first paint. A store of each client's,
 * which hears the client's settings as they come, outside any component.
 */
import { useSyncExternalStore } from "react";
import type { Client, DeviceSettings, Settings } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { DEVICE_DEFAULTS, type Device, type DeviceChange, deviceOf } from "../../core/device.ts";
import { failed } from "./notices.ts";

/** Where the browser keeps its copy. */
const KEY = "octoii.device";

/** The browser's copy of what the node told of this device last; none where it keeps none, as in a private window. */
function copied(): DeviceSettings {
	try {
		const text = localStorage.getItem(KEY);
		const kept: unknown = text === null ? undefined : JSON.parse(text);
		return typeof kept === "object" && kept !== null && !Array.isArray(kept) ? Object.fromEntries(Object.entries(kept)) : {};
	} catch {
		return {};
	}
}

function copy(kept: DeviceSettings): void {
	try {
		localStorage.setItem(KEY, JSON.stringify(kept));
	} catch {
		// A browser that keeps nothing, as in a private window, starts from the defaults.
	}
}

/** `kept` with each change laid over it: a name given its value, or let go where it is null. */
function laidOver(kept: DeviceSettings, changes: Readonly<Record<string, unknown>>): DeviceSettings {
	const over: Record<string, unknown> = { ...kept };
	for (const [name, value] of Object.entries(changes)) {
		if (value === null) delete over[name];
		else over[name] = value;
	}
	return over;
}

/** Whether `kept` holds a change as it was made. */
function holds(kept: DeviceSettings, name: string, value: unknown): boolean {
	return value === null ? !(name in kept) : JSON.stringify(kept[name]) === JSON.stringify(value);
}

/** A client's store of what is set for this device. */
class DeviceStore {
	readonly #client: Client;
	readonly #listeners = new Set<() => void>();
	/** What the node told last, else the browser's copy. */
	#kept: DeviceSettings = copied();
	/** The changes made here the node has not told of yet: each name's value, or null where it is let go. */
	#laid: Readonly<Record<string, unknown>> = {};
	#device: Device;

	constructor(client: Client) {
		this.#client = client;
		this.#device = deviceOf(this.#kept);
		// Watched as long as the client lives: the page always shows as the device is set.
		const settings = client.watchSettings();
		settings.subscribe(() => this.#heard(settings.view()));
		this.#heard(settings.view());
	}

	readonly subscribe = (listener: () => void): (() => void) => {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	};

	readonly view = (): Device => this.#device;

	/** Sets what `change` sets, laid over what the node holds till it tells of it. */
	readonly set = (change: Readonly<Record<string, unknown>>): void => {
		this.#laid = { ...this.#laid, ...change };
		this.#publish();
		this.#client.setSettings({ device: change }).catch((error: unknown) => failed("The setting could not be kept", error));
	};

	/** What the node told: kept, copied for the next page's first paint, and what it now holds of the changes made here its own again. */
	#heard(settings: Settings | undefined): void {
		if (settings === undefined) return;
		this.#kept = settings.device;
		copy(settings.device);
		const kept = settings.device;
		this.#laid = Object.fromEntries(Object.entries(this.#laid).filter(([name, value]) => !holds(kept, name, value)));
		this.#publish();
	}

	#publish(): void {
		this.#device = deviceOf(laidOver(this.#kept, this.#laid));
		for (const listener of [...this.#listeners]) listener();
	}
}

/** Each client's store, made as it is first read. */
const stores = new WeakMap<Client, DeviceStore>();

/** What is set for this device; how to change it; and how to put it back as it came. */
export function useDevice(): { readonly device: Device; readonly set: (change: DeviceChange) => void; readonly restore: () => void } {
	const client = useClient();
	let store = stores.get(client);
	if (store === undefined) {
		store = new DeviceStore(client);
		stores.set(client, store);
	}
	const device = useSyncExternalStore(store.subscribe, store.view);
	const { set } = store;
	return { device, set, restore: () => set(Object.fromEntries(Object.keys(DEVICE_DEFAULTS).map((name) => [name, null]))) };
}
