#!/usr/bin/env bash
# Builds the two WebAssembly modules in vendor/ from source: libghostty-vt 1.0.0, at the commit of its tag vt-1.0.0, and the
# terminal's callbacks from native/callbacks.zig. Zig and Ghostty's source are fetched into ~/.cache/octoii once.
#
#   packages/terminal/scripts/build-wasm.sh

set -euo pipefail

GHOSTTY_COMMIT="0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec"
ZIG_VERSION="0.17.0"

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${HOME}/.cache/octoii"
ZIG="${CACHE}/zig-${ZIG_VERSION}/zig"
GHOSTTY="${CACHE}/ghostty"

fetch_zig() {
	[[ -x "${ZIG}" ]] && return
	local os arch
	case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) echo "no Zig for $(uname -s)" >&2; exit 1 ;; esac
	case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; x86_64) arch=x86_64 ;; *) echo "no Zig for $(uname -m)" >&2; exit 1 ;; esac
	mkdir -p "$(dirname "${ZIG}")"
	curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-${os}-${ZIG_VERSION}.tar.xz" |
		tar -xJ --strip-components=1 -C "$(dirname "${ZIG}")"
}

fetch_ghostty() {
	[[ -d "${GHOSTTY}/.git" ]] || git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "${GHOSTTY}"
	if [[ "$(git -C "${GHOSTTY}" rev-parse HEAD)" != "${GHOSTTY_COMMIT}" ]]; then
		git -C "${GHOSTTY}" fetch --depth=1 origin "${GHOSTTY_COMMIT}"
		git -C "${GHOSTTY}" checkout --detach "${GHOSTTY_COMMIT}"
	fi
}

fetch_zig
fetch_ghostty

out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT
(
	cd "${GHOSTTY}"
	"${ZIG}" build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall -Dstrip=true -p "${out}"
)
cp "${out}/bin/ghostty-vt.wasm" "${PACKAGE}/vendor/ghostty-vt.wasm"
"${ZIG}" build-exe "${PACKAGE}/native/callbacks.zig" -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
	-femit-bin="${out}/callbacks.wasm"
cp "${out}/callbacks.wasm" "${PACKAGE}/vendor/callbacks.wasm"
chmod 0644 "${PACKAGE}"/vendor/*.wasm
echo "Built vendor/ghostty-vt.wasm (Ghostty ${GHOSTTY_COMMIT:0:9}) and vendor/callbacks.wasm"
