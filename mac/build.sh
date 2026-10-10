#!/bin/zsh
# Builds StemMixer.app into ./build. Pass --install to copy it to /Applications as well.
# The app runs ../server.py with ../.venv, so keep this folder where it is after building.
set -euo pipefail
cd "$(dirname "$0")"
BACKEND="$(cd .. && pwd)"

swift build -c release

APP=build/StemMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/StemMixer" "$APP/Contents/MacOS/StemMixer"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>StemMixer</string>
    <key>CFBundleDisplayName</key><string>StemMixer</string>
    <key>CFBundleIdentifier</key><string>com.kain.stemmixer</string>
    <key>CFBundleExecutable</key><string>StemMixer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>StemMixerBackend</key><string>$BACKEND</string>
    <key>NSMicrophoneUsageDescription</key><string>내 목소리나 악기를 녹음해서 트랙 대신 넣을 때 마이크를 써요.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/StemMixer.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/StemMixer.app"
fi
