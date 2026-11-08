/**
 * The thread whose messages a page shows, which what they name is read against: a path from its folder, a page of its
 * browser by its id — given by the page that shows the thread, none where a page shows messages of no thread.
 */
import { createContext } from "react";
import type { PageListed } from "@octoii-works/octoii-client";

/** The thread of the messages shown: its id, the folder its paths start from — none where it has none — and its pages in the browser. */
export type MessageThread = { readonly thread: string; readonly workspace: string | undefined; readonly pages: readonly PageListed[] };

/** The thread of the messages shown; none where they are no thread's. */
export const MessageThreadContext = createContext<MessageThread | undefined>(undefined);
