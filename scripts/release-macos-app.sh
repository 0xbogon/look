#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/macos/LauncherApp"
SCHEME="Look"
CONFIGURATION="Release"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y.%m.%d)"
fi

BUILD_DIR="$ROOT_DIR/.build/release-macos"
OUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Look.app"
ZIP_NAME="Look-${VERSION}-macOS.zip"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"

echo "[1/4] Cleaning previous release artifacts"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

# ARCHS override: ARCHS=x86_64 ./scripts/release-macos-app.sh 0.1.1 → single-arch
# release. The Rust FFI phase follows $ARCHS, so the .a matches automatically.
if [[ -n "${ARCHS:-}" ]]; then
  ARCHS_FLAG=(ARCHS="$ARCHS")
else
  ARCHS_FLAG=()
fi

echo "[2/4] Building macOS app ($CONFIGURATION)"
# -destination "generic/platform=macOS" = "Any Mac": builds every arch in ARCHS
# (arm64 + x86_64). Omitting it lets xcodebuild auto-pick a destination, and on
# a dev Mac that is the concrete "My Mac" machine (arch:arm64), which silently
# collapses the build to a single arch despite ARCHS = "arm64 x86_64".
xcodebuild \
  -project "$APP_DIR/look-app.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build ${ARCHS_FLAG[@]+"${ARCHS_FLAG[@]}"} >/dev/null

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded but app bundle not found at: $APP_PATH" >&2
  exit 1
fi

echo "[3/4] Packaging app bundle"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[4/4] Calculating sha256"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo
echo "Release artifact ready:"
echo "  File: $ZIP_PATH"
echo "  SHA256: $SHA256"
echo
echo "Use this URL+SHA256 in your Homebrew cask."
