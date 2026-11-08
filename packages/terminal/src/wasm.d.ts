/** A WebAssembly file imported by the bundler, which gives its URL. */
declare module "*.wasm" {
	const url: string;
	export default url;
}
