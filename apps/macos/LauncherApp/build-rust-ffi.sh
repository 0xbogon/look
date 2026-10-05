#!/bin/bash
# Build bridge/ffi for every architecture Xcode is building, then merge the
# slices into one static library at RustBuild/liblook_ffi.a.
#
# The app links this library with -Wl,-force_load, so the Rust slices must
# cover every arch the app binary contains. Both aarch64-apple-darwin and
# x86_64-apple-darwin are first-class targets of the macOS SDK: cross-building
# from Apple Silicon to x86_64 (and the reverse on Intel) needs no extra
# toolchain, just `cargo build --target <triple>`.
#
# Xcode exports ARCHS, ONLY_ACTIVE_ARCH, CONFIGURATION and PROJECT_DIR into
# the build phase environment. Debug builds run with ONLY_ACTIVE_ARCH=YES,
# so dev loops compile only the host arch; release builds compile the full
# ARCHS list (arm64 x86_64) and lipo the fat .a, keeping the release app
# universal.
#
# Run standalone (from any cwd) to test:
#   ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CONFIGURATION=Debug \
#   PROJECT_DIR="$PWD/apps/macos/LauncherApp" ./apps/macos/LauncherApp/build-rust-ffi.sh

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
ARCHS="${ARCHS:-$(uname -m)}"

FFI_MANIFEST="$PROJECT_DIR/../../../bridge/ffi/Cargo.toml"
FFI_TARGET_DIR="$PROJECT_DIR/../../../bridge/ffi/target"
OUT_LIB="$PROJECT_DIR/RustBuild/liblook_ffi.a"

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  PROFILE=release
  CARGO_FLAGS=--release
else
  PROFILE=debug
  CARGO_FLAGS=""
fi

if [ -x "$HOME/.cargo/bin/cargo" ]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
else
  CARGO_BIN=cargo
fi

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

# Slices = the architectures Xcode will link. Always build every $ARCHS:
# Debug sets ONLY_ACTIVE_ARCH=YES, but for a generic destination Xcode ignores
# it and links every ARCHS — a single uname -m slice would then fail the link.
# The extra slice is harmless (cargo is incremental); a missing slice is not.
BUILD_ARCHS="$ARCHS"

triple_for() {
  case "$1" in
    arm64) printf 'aarch64-apple-darwin' ;;
    x86_64) printf 'x86_64-apple-darwin' ;;
    *) echo "error: unsupported arch for Rust FFI: $1" >&2; return 1 ;;
  esac
}

mkdir -p "$PROJECT_DIR/RustBuild"

build_slicing() {
  local arch triple
  local slices=()
  local cargo_log="$PROJECT_DIR/RustBuild/cargo-ffi-build.log"
  for arch in $BUILD_ARCHS; do
    triple="$(triple_for "$arch")"
    echo "Building Rust FFI slice: $triple"
    if ! "$CARGO_BIN" +nightly build --manifest-path "$FFI_MANIFEST" --target "$triple" $CARGO_FLAGS 2>&1 | tee "$cargo_log"; then
      case "$(cat "$cargo_log" 2>/dev/null)" in
        *"may not be installed"*)
          echo "error: rust target $triple is not installed on the nightly toolchain." >&2
          echo "hint: rustup target add $triple --toolchain nightly" >&2 ;;
        *)
          echo "error: cargo build failed for $triple; last lines of output above." >&2 ;;
      esac
      return 1
    fi
    slices+=("$FFI_TARGET_DIR/$triple/$PROFILE/liblook_ffi.a")
  done

  if [ "${#slices[@]}" -eq 1 ]; then
    cp "${slices[0]}" "$OUT_LIB"
  else
    if ! lipo -create "${slices[@]}" -output "$OUT_LIB"; then
      echo "error: lipo failed merging: ${slices[*]}" >&2
      return 1
    fi
  fi
}

if build_slicing; then
  echo "Rust FFI built for: $BUILD_ARCHS"
else
  if [ "$PROFILE" = "release" ]; then
    # Never ship a Release build on a stale archive: a failed slice build would
    # otherwise fall back to the previous fat liblook_ffi.a, and the arch check
    # would still pass with old Rust code packaged.
    echo "error: Rust FFI build failed for a Release build; refusing to reuse an existing archive" >&2
    exit 1
  fi
  # Debug: a Rust failure warns and reuses the last built library so a
  # Swift-only iteration is not blocked by a broken Rust toolchain.
  echo "warning: Rust build skipped; using existing RustBuild/liblook_ffi.a"
  if [ ! -f "$OUT_LIB" ]; then
    echo "error: missing fallback RustBuild/liblook_ffi.a"
    exit 1
  fi
fi
