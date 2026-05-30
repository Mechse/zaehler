#!/usr/bin/env bash
set -euo pipefail

# Build the zlr binary.
# Requires Odin on your PATH: https://odin-lang.org/docs/install/

OUT="${1:-zlr}"
SRC_DIR="src"

echo "building ${OUT} from ${SRC_DIR}/ ..."
odin build "${SRC_DIR}" -out:"${OUT}" -o:speed
echo "done -> ./${OUT}"
