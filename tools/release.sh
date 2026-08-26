#!/usr/bin/env bash
# Build a complete CocoaMojo release from a clean checkout.
#
#   ./tools/release.sh
#
# Two steps: bazel builds the compiler, then make-dist.sh assembles a
# distribution that does not need bazel again. See RELEASE.md for why each
# flag is there.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1/2  building the compiler (this is the long one) =="
./bazelw build --config=build-mojo --config=release //KGEN/tools/mojo:mojo

echo
echo "== 2/2  assembling dist/CocoaMojo =="
./tools/make-dist.sh

echo
echo "Verify with:  ./tools/check-dist.sh"
