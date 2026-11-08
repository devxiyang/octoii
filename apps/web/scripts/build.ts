/**
 * Builds the interface's two pages — the one a node serves, into `dist/`, and the one at the app's address, into
 * `dist-hosted/` — each with its Tailwind styles and fonts, minified, what it first needs later in files of their own,
 * each named from the root, as a page is served at every path of the app, `/auth/callback` among them.
 *
 *   bun scripts/build.ts
 */
import { cp, readFile, rm, writeFile } from "node:fs/promises";
import tailwind from "bun-plugin-tailwind";

const root = new URL("..", import.meta.url).pathname;

/** What the page at the app's address links, for a browser to install it; written here as the bundler would try to bundle them. */
const INSTALL_LINKS =
	'<link rel="manifest" href="/manifest.webmanifest"><link rel="icon" href="/icon-192.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">';

/** Builds the page at `entry` into `outdir`, which it empties first. */
async function buildPage(entry: string, outdir: string): Promise<void> {
	await rm(outdir, { recursive: true, force: true });
	const result = await Bun.build({
		entrypoints: [entry],
		outdir,
		target: "browser",
		// The page is served at every path of the app, so what it loads is named from the root, never beside the path.
		publicPath: "/",
		minify: true,
		// What the page imports when it first needs it, such as a viewer, comes in a file of its own.
		splitting: true,
		// React's production build: a third of the development build's size, without its checks.
		define: { "process.env.NODE_ENV": JSON.stringify("production") },
		plugins: [tailwind],
	});
	if (result.success) return;
	for (const log of result.logs) console.error(log);
	throw new Error("The interface did not build");
}

/** Builds the page a node serves into `outdir`. */
export function buildWeb(outdir: string): Promise<void> {
	return buildPage(`${root}src/index.html`, outdir);
}

/** Builds the page at the app's address into `outdir`, with what its host and a browser installing it read. */
async function buildHosted(outdir: string): Promise<void> {
	await buildPage(`${root}src/hosted/index.html`, outdir);
	await cp(`${root}src/hosted/public`, outdir, { recursive: true });
	const page = `${outdir}/index.html`;
	await writeFile(page, (await readFile(page, "utf8")).replace("</head>", `${INSTALL_LINKS}</head>`));
}

if (import.meta.main) {
	await buildWeb(`${root}dist`);
	await buildHosted(`${root}dist-hosted`);
	console.log(`Built into ${root}dist and ${root}dist-hosted`);
}
