#!/bin/sh
# Builds Beak from its checkout beside this repository — or at BEAK_DIR — and brings its static library and header
# here, to vendor/beak/<arch>-<os>/, for this machine. They stay out of git; an open checkout of Octoii will fetch them
# from Beak's releases instead.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
beak=${BEAK_DIR:-$(cd "$here/../../.." && pwd)/octoii-beak}
optimize=${BEAK_OPTIMIZE:-debug}
case "$(uname -s)" in
	Darwin) os=macos ;;
	Linux) os=linux ;;
	*) echo "beak.sh: no build of Beak for $(uname -s) here" >&2; exit 1 ;;
esac
case "$(uname -m)" in
	arm64 | aarch64) arch=aarch64 ;;
	x86_64) arch=x86_64 ;;
	*) echo "beak.sh: no build of Beak for $(uname -m) here" >&2; exit 1 ;;
esac
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
(cd "$beak" && zig build library -Doptimize="$optimize" --prefix "$staging")
into="$here/vendor/beak/$arch-$os"
mkdir -p "$into"
cp "$staging/lib/libbeak.a" "$staging/include/beak.h" "$into/"
echo "beak.sh: $into"
