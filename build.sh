#!/bin/bash
# Builds Todo.app next to this script. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=Todo.app

if [ ! -f AppIcon.icns ]; then
  T=$(mktemp -d)
  swift icon.swift "$T/icon.png"
  mkdir "$T/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
  rm -rf "$T"
fi

SDK=$(xcrun --show-sdk-path)
# The macOS 27 SDK implements @State as a macro whose plugin ships only with Xcode,
# so with just the Command Line Tools build against the 26.x SDK instead.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]] && ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk >/dev/null 2>&1; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk | tail -1)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -sdk "$SDK" -target "$(uname -m)-apple-macos15.0" Model.swift Views.swift TaskViews.swift AI.swift -o "$APP/Contents/MacOS/Todo"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Todo</string>
  <key>CFBundleDisplayName</key><string>Todo</string>
  <key>CFBundleIdentifier</key><string>local.todo.app</string>
  <key>CFBundleExecutable</key><string>Todo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

# ./build.sh install  also copies the app to /Applications (Launchpad, Spotlight, Dock).
if [ "${1:-}" = "install" ]; then
  pkill -x Todo || true
  rm -rf /Applications/Todo.app
  ditto "$APP" /Applications/Todo.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Todo.app
  echo "Installed /Applications/Todo.app"
fi
