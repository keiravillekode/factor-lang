#!/bin/sh
# Build the VMs run.py uses into misc/fuzz/vms/ (or $OUT):
#
#   factor-cpp   C++ VM, the oracle         (./build.sh compile)
#   debug/       Zig VM, Debug              (zig build)
#   safe/        Zig VM, ReleaseSafe        (zig build -Doptimize=ReleaseSafe)
#
#   misc/fuzz/build-vms.sh [cpp] [debug] [safe]     (default: all three)
#
# Both builds write ./factor at the repository root; this script puts the
# previous ./factor back. Needs Zig 0.16 as $ZIG (default: zig on PATH).
# factor.image must come from ./build.sh net-bootstrap (or update) first.
set -eu

ZIG=${ZIG:-zig}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/misc/fuzz/vms}
[ $# -eq 0 ] && set -- cpp debug safe

cd "$ROOT"
mkdir -p "$OUT"

saved=
if [ -e factor ] || [ -L factor ]; then
    saved=$(mktemp "$ROOT/factor.saved.XXXXXX")
    cp -P factor "$saved"
fi
restore() {
    if [ -n "$saved" ]; then mv -f "$saved" factor; else rm -f factor; fi
}
trap restore EXIT

for vm in "$@"; do
    case $vm in
        cpp)
            ./build.sh compile
            cp -L factor "$OUT/factor-cpp"
            ;;
        debug)
            "$ZIG" build --prefix "$OUT/debug"
            ;;
        safe)
            "$ZIG" build -Doptimize=ReleaseSafe --prefix "$OUT/safe"
            ;;
        *)
            echo "unknown VM '$vm' (expected cpp, debug or safe)" >&2
            exit 2
            ;;
    esac
done
ls -l "$OUT"/factor-cpp "$OUT"/*/bin/factor 2>/dev/null || true
