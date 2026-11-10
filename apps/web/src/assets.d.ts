/** A file the page imports as it is, an image: the address the build serves it at. */
declare module "*.svg" {
	const address: string;
	export default address;
}
