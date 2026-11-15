#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then echo "This build requires macOS and Xcode Command Line Tools." >&2; exit 1; fi
swift test
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/RizzoCharge.app"
rm -rf "$APP" dist/RizzoCharge.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/RizzoCharge.iconset
cp "$BIN_DIR/RizzoCharge" "$APP/Contents/MacOS/RizzoCharge"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/RizzoCharge.png --out "dist/RizzoCharge.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size*2))
  sips -z "$double" "$double" Assets/RizzoCharge.png --out "dist/RizzoCharge.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns dist/RizzoCharge.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>RizzoCharge</string><key>CFBundleIdentifier</key><string>com.rizzocharge.app</string><key>CFBundleName</key><string>RizzoCharge</string><key>CFBundleDisplayName</key><string>RizzoCharge</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.2.1</string><key>CFBundleVersion</key><string>3</string><key>LSUIElement</key><true/><key>CFBundleIconFile</key><string>AppIcon</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/RizzoCharge-macOS-unsigned.zip
shasum -a 256 dist/RizzoCharge-macOS-unsigned.zip > dist/SHA256SUMS.txt
echo "Built $APP (ad-hoc signed, not notarized)"
