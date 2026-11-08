/** The client's numbers: reconnecting, how many of a thread's entries it keeps, and how long its hooks keep what no component reads. */

/** The first wait before connecting again, in ms, doubled at each attempt. */
export const RECONNECT_MIN_MS = 500;

/** The longest wait before connecting again, in ms. */
export const RECONNECT_MAX_MS = 30_000;

/** How many of a thread's latest entries a client keeps, where its options name no other: more only while a reader reads further back. */
export const ENTRIES_KEPT = 500;

/** How many entries a read further back takes at a time. */
export const READ_BACK_PAGE = 100;

/** How long `/react` keeps what no component subscribes to, in ms. */
export const REACT_RELEASE_MS = 1_000;
