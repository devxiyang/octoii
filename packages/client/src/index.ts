/**
 * Octoii's client: `createClient`, which speaks the node's protocol over one WebSocket, follows threads from where their
 * readers stood after a lost connection, and does a person's operations once; the protocol's types and schemas, so an
 * app imports this package alone; and its hooks for React at `/react`.
 */
export { type Client, createClient } from "./client.ts";
export type { ConnectionStatus } from "./connection.ts";
export { type Ask, type Call, type Conversation, conversationOf, type Step, type Turn } from "./conversation.ts";
export * from "./constants.ts";
export { ClientError, type ClientCode } from "./errors.ts";
export { type Followable, type Followed, Value } from "./followed.ts";
export type { ClientOptions, Clock, KeptFile, WebSocketLike } from "./options.ts";
export * from "./protocol.ts";
export { matches, parsed, InvalidValueError } from "./std/schema.ts";
export type { TerminalHandlers, TerminalSize, TerminalView } from "./terminals.ts";
export type { PageFrame, PageHandlers, PageSize, PageView } from "./pages.ts";
export type { ThreadView } from "./thread.ts";
export type { ThreadsView } from "./threads.ts";
