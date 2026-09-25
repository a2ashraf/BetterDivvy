#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/BetterDivvy.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O Sources/main.swift -o $APP/Contents/MacOS/BetterDivvy
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>BetterDivvy</string>
<key>CFBundleExecutable</key><string>BetterDivvy</string>
<key>CFBundleIdentifier</key><string>local.ahsan.betterdivvy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - $APP
