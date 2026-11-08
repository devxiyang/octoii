/**
 * The app's notices, at the top right over everything: each on a menu's glass, its icon by its kind — a failure's in
 * the error's colour, never the colour alone telling it — its title and why, a way to copy a failure's words, and a
 * cross; stacked newest first, three at most, the rest waiting their turn; slid in from the edge, slid away to it by
 * a swipe, and held while pointed at or focused, as Base UI's toasts are. Moving nothing where the person asks for
 * less motion.
 */
import type { ReactNode } from "react";
import { Toast } from "@base-ui/react/toast";
import { CircleAlert, CircleCheck, Info, X } from "lucide-react";
import { notices } from "../state/notices.ts";
import { CopyButton } from "./copy-button.tsx";

/** The app, with its notices shown over it. */
export function NoticesProvider(props: { readonly children: ReactNode }): ReactNode {
	return (
		<Toast.Provider toastManager={notices} limit={3}>
			{props.children}
			<Notices />
		</Toast.Provider>
	);
}

/** Each kind of notice's icon and its colour. */
const ICONS = {
	error: { icon: CircleAlert, tone: "text-error-foreground" },
	success: { icon: CircleCheck, tone: "text-success-foreground" },
	info: { icon: Info, tone: "text-info-foreground" },
} as const;

function iconOf(type: string | undefined): (typeof ICONS)[keyof typeof ICONS] {
	return type === "error" || type === "success" ? ICONS[type] : ICONS.info;
}

function Notices(): ReactNode {
	const { toasts } = Toast.useToastManager();
	return (
		<Toast.Portal>
			<Toast.Viewport className="fixed top-4 right-4 z-[150] w-[min(22rem,calc(100vw-2rem))] outline-none">
				{toasts.map((toast) => {
					const { icon: Icon, tone } = iconOf(toast.type);
					return (
						<Toast.Root
							key={toast.id}
							toast={toast}
							swipeDirection={["right", "up"]}
							className={
								"menu-glass absolute top-0 right-0 w-full rounded-lg text-sm text-popover-foreground select-none " +
								"[transform:translateX(var(--toast-swipe-movement-x))_translateY(calc(var(--toast-offset-y)+var(--toast-index)*0.5rem+var(--toast-swipe-movement-y)))] " +
								"transition-[transform,opacity] duration-300 ease-[cubic-bezier(.22,1,.36,1)] motion-reduce:transition-none " +
								"data-limited:opacity-0 data-starting-style:[transform:translateX(calc(100%+1rem))] " +
								"data-ending-style:opacity-0 data-ending-style:not-data-swipe-direction:[transform:translateX(calc(100%+1rem))_translateY(var(--toast-offset-y))]"
							}
						>
							<Toast.Content className="flex items-start gap-2 py-2.5 ps-3 pe-2">
								<Icon className={`mt-0.5 size-4 shrink-0 ${tone}`} aria-hidden />
								<div className="min-w-0 flex-1">
									<Toast.Title className="font-medium break-words" />
									<Toast.Description className="mt-0.5 text-xs break-words text-muted-foreground" />
								</div>
								{toast.type === "error" ? (
									<CopyButton text={[toast.title, toast.description].filter((part) => typeof part === "string").join(": ")} label="Copy the words" />
								) : null}
								<Toast.Close
									aria-label="Dismiss"
									className="flex size-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
								>
									<X className="size-3.5" />
								</Toast.Close>
							</Toast.Content>
						</Toast.Root>
					);
				})}
			</Toast.Viewport>
		</Toast.Portal>
	);
}
