#!/bin/bash
# Builds SkinLab.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="SkinLab.app"
OBJ=".build/obj"
mkdir -p "$OBJ"

# C support: xxhash + zstd decoder
for src in CSupport/csupport.c CSupport/zstd/common/*.c CSupport/zstd/decompress/*.c; do
  clang -c -O2 -arch arm64 -mmacosx-version-min=14.0 -DZSTD_DISABLE_ASM -DZSTD_MULTITHREAD=0 \
    -ICSupport -ICSupport/zstd "$src" -o "$OBJ/$(echo "$src" | tr / _).o"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Icon/AppIcon.icns ] && cp Icon/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -wmo -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header CSupport/csupport.h \
  Sources/*.swift "$OBJ"/*.o \
  -lz -o "$APP/Contents/MacOS/SkinLab"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SkinLab</string>
  <key>CFBundleIdentifier</key><string>local.skinlab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>SkinLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
