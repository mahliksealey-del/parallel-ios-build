#!/bin/bash
set -euo pipefail

APP_PATH="${1:?usage: package-unsigned.sh path/to/Parallel.app [output.ipa]}"
OUTPUT_PATH="${2:-Parallel-unsigned.ipa}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$OLDPWD/$OUTPUT_PATH" Payload
)

echo "Created unsigned signing input: $OUTPUT_PATH"
echo "This file is not installable until properly signed and provisioned."
