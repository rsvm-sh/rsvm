#!/usr/bin/env bash
# rsvm-exec — run a command under a specific Rust version
# Usage: rsvm-exec <version> <command> [args...]
#        rsvm-exec -- <command> [args...]   (reads version from .rust-version)
#
# Useful in CI, Makefiles, and non-interactive shells where sourcing rsvm.sh
# is not practical.

set -e

RSVM_DIR="${RSVM_DIR:-$HOME/.rsvm}"

if [[ -z "${1:-}" ]]; then
  echo "Usage: rsvm-exec <version> <command> [args...]"
  echo "       rsvm-exec -- <command> [args...]"
  echo ""
  echo "Examples:"
  echo "  rsvm-exec 1.75.0 cargo build"
  echo "  rsvm-exec stable cargo test"
  echo "  rsvm-exec -- cargo build   # reads from .rust-version"
  exit 1
fi

VERSION="$1"; shift

# Read version from the nearest .rust-version file
if [[ "$VERSION" == "--" ]]; then
  RUST_VER_FILE=""
  dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.rust-version" ]]; then
      RUST_VER_FILE="$dir/.rust-version"
      break
    fi
    dir="$(dirname "$dir")"
  done
  if [[ -z "$RUST_VER_FILE" ]]; then
    echo "rsvm-exec: no .rust-version file found" >&2
    exit 1
  fi
  VERSION="$(cat "$RUST_VER_FILE")"
fi

VERSION_BIN="$RSVM_DIR/versions/$VERSION/bin"

if [[ -d "$VERSION_BIN" ]]; then
  exec env PATH="$VERSION_BIN:$PATH" "$@"
elif command -v rustup &>/dev/null; then
  exec rustup run "$VERSION" "$@"
else
  echo "rsvm-exec: version $VERSION is not installed" >&2
  exit 1
fi
