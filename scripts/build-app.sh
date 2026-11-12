#!/bin/zsh
# Builds dist/ClipDown.app and dist/ClipDown-<version>.zip
#   ./scripts/build-app.sh [version]            # native architecture
#   UNIVERSAL=1 ./scripts/build-app.sh 1.0.0    # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
BUNDLE_ID="io.github.xcnccw.clipdown"
APP="dist/ClipDown.app"

ARCHS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCHS=(--arch arm64 --arch x86_64)

echo "==> Building release binary"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/ClipDown"

echo "==> Generating icon"
rm -rf dist/AppIcon.iconset && mkdir -p dist
swift scripts/make-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipDown"
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClipDown</string>
    <key>CFBundleDisplayName</key><string>ClipDown</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>ClipDown</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Zipping"
rm -f "dist/ClipDown-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "dist/ClipDown-${VERSION}.zip"

echo "Done: $APP  and  dist/ClipDown-${VERSION}.zip"
