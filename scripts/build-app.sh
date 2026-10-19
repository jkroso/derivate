#!/bin/sh
# Builds build/Derivate.app: the release binary for Apple silicon and Intel,
# its Info.plist and its icon, signed for this Mac.
#
#   scripts/build-app.sh              build/Derivate.app
#   scripts/build-app.sh --install    builds it, quits the running copy, puts the
#                                     new one in ~/Applications and opens it
#
# SIGN_IDENTITY names a certificate in the keychain, such as
# "Developer ID Application". The app is then signed with it, with the
# hardened runtime and a secure timestamp, as Apple's notary service asks.
# scripts/release.sh sets it.
set -eu
cd "$(dirname "$0")/.."

version=1.1.0
app=build/Derivate.app

arch="--arch arm64 --arch x86_64"
swift build -c release $arch --product Derivate
bin=$(swift build -c release $arch --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Derivate" "$app/Contents/MacOS/Derivate"

# The icon, at every size macOS asks for.
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size resources/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double resources/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Derivate</string>
    <key>CFBundleDisplayName</key><string>Derivate</string>
    <key>CFBundleIdentifier</key><string>dev.derivate.app</string>
    <key>CFBundleExecutable</key><string>Derivate</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Your passwords from your name and master password, in the menu bar</string>
</dict>
</plist>
EOF

identity=${SIGN_IDENTITY:--}
if [ "$identity" = - ]; then
    codesign --force --sign - "$app"
else
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
fi
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
    installed="$HOME/Applications/Derivate.app"
    osascript -e 'tell application id "dev.derivate.app" to quit' 2>/dev/null || true
    # AI agents run the same file as `Derivate mcp`, which stays running:
    # wait for the menu bar app alone, and for 10 seconds at most.
    for _ in $(seq 50); do pgrep -fx "$installed/Contents/MacOS/Derivate" >/dev/null || break; sleep 0.2; done
    mkdir -p "$HOME/Applications"
    rm -rf "$installed"
    ditto "$app" "$installed"
    echo "Installed $installed"
    # Launch Services may still be letting the old copy go.
    open "$installed" 2>/dev/null || { sleep 1; open "$installed"; }
fi
