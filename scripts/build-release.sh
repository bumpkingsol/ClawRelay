#!/bin/bash
# Build and package ClawRelay for GitHub Release
# Usage: bash scripts/build-release.sh [--publish]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(grep 'MARKETING_VERSION' "$ROOT_DIR/mac-helper/OpenClawHelper.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= //' | tr -d ';[:space:]')
ZIP_NAME="ClawRelay-v${VERSION}.zip"
BUILD_DIR="$ROOT_DIR/mac-helper/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/ClawRelay.app"

echo "=== Building ClawRelay v${VERSION} ==="

# Clean and build Release
xcodebuild -project "$ROOT_DIR/mac-helper/OpenClawHelper.xcodeproj" \
  -scheme OpenClawHelper \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  clean build 2>&1 | grep -E '(BUILD|error:|warning:)' || true

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed - $APP_PATH not found" >&2
  exit 1
fi

echo "Build succeeded: $APP_PATH"
echo "Binary: $(file "$APP_PATH/Contents/MacOS/ClawRelay" | cut -d: -f2)"

# Zip
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ROOT_DIR/$ZIP_NAME"
echo "Packaged: $ZIP_NAME ($(du -h "$ROOT_DIR/$ZIP_NAME" | cut -f1 | xargs))"

# Publish to GitHub Releases
if [ "${1:-}" = "--publish" ]; then
  echo "Publishing to GitHub..."
  gh release create "v${VERSION}" "$ROOT_DIR/$ZIP_NAME" \
    --title "ClawRelay v${VERSION}" \
    --notes "$(cat <<EOF
## ClawRelay v${VERSION}

Native macOS helper app for controlling the Context Bridge capture pipeline.

### Features
- Menu bar popover with live status, health strip, and quick actions
- Control Center with Overview, Permissions, Privacy, and Diagnostics tabs
- Pause/Resume/Sensitive Mode controls
- Permission detection and repair guidance
- Handoff composer for task delegation

### Requirements
- macOS 14.0+ (Sonoma or later)
- Context Bridge daemon installed (\`bash mac-daemon/install.sh\`)

### Install
1. Download \`$ZIP_NAME\`
2. Unzip and move \`ClawRelay.app\` to Applications
3. On first launch: right-click > Open (unsigned app)
EOF
)"
  echo "Release published: https://github.com/bumpkingsol/ClawRelay/releases/tag/v${VERSION}"
else
  echo ""
  echo "To publish: bash scripts/build-release.sh --publish"
  echo "Or manually: gh release create v${VERSION} $ZIP_NAME --title 'ClawRelay v${VERSION}'"
fi
