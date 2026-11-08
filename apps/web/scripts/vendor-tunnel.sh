#!/usr/bin/env bash
# Copies the session a browser runs into vendor/tunnel/, from the tunnel the node is pinned to, so that the web app and the
# node speak one version and the app builds without Zig.
#
#   apps/web/scripts/vendor-tunnel.sh

set -euo pipefail

WEB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${WEB}/../../packages/node"

(cd "${NODE}" && zig build page-client)
install -m 644 "${NODE}/zig-out/page/tunnel.wasm" "${NODE}/zig-out/page/tunnel.js" "${NODE}/zig-out/page/tunnel.d.ts" "${WEB}/vendor/tunnel/"
