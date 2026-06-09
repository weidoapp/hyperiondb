#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="pg_replica"
EXPECTED="${1:-}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${ROOT}/Cargo.toml" | head -1)"
PREFIX="${EXT}-${VERSION}"
TAG="v${VERSION}"
OUT_DIR="${ROOT}/dist"
ARCHIVE="${OUT_DIR}/${PREFIX}.zip"

cd "$ROOT"

if [ -n "$EXPECTED" ] && [ "${EXPECTED#v}" != "$VERSION" ]; then
  echo "version arg '$EXPECTED' does not match Cargo.toml=$VERSION" >&2
  exit 1
fi

if [ ! -f META.json ]; then
  echo "missing META.json at repo root" >&2
  exit 1
fi

META_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' META.json | head -1)"
if [ "$META_VERSION" != "$VERSION" ]; then
  echo "version mismatch: Cargo.toml=$VERSION META.json=$META_VERSION" >&2
  exit 1
fi

if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  git tag "$TAG" HEAD
fi

mkdir -p "$OUT_DIR"
rm -f "$ARCHIVE"
git archive --format=zip --prefix="${PREFIX}/" -o "$ARCHIVE" "$TAG"

echo "built $ARCHIVE"

if command -v pgxn-validate-meta >/dev/null 2>&1; then
  ( cd "$OUT_DIR" && rm -rf "$PREFIX" && unzip -q "$ARCHIVE" && pgxn-validate-meta "$PREFIX/META.json" && rm -rf "$PREFIX" )
fi
