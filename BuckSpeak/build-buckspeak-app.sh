#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="BuckSpeak"
APP_PATH="/Applications/${APP_NAME}.app"
CONTENTS_DIR="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_PATH="${MACOS_DIR}/${APP_NAME}"
SWIFT_SOURCES=("${SCRIPT_DIR}"/*.swift)

rm -rf "${APP_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

/usr/bin/swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  "${SWIFT_SOURCES[@]}" \
  -o "${EXECUTABLE_PATH}"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>BuckSpeak</string>
    <key>CFBundleIdentifier</key>
    <string>com.rjamesy.buckspeak</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BuckSpeak</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>BuckSpeak uses the microphone to listen for ARIA responses.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>BuckSpeak uses speech recognition to transcribe ARIA responses.</string>
</dict>
</plist>
EOF

/usr/bin/codesign --force --sign - --deep "${APP_PATH}"
/usr/bin/xattr -cr "${APP_PATH}"

echo "Built ${APP_PATH}"
