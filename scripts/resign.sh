#!/bin/bash
# Re-sign VoiceInk.app inside-out with a stable identity, keeping each component's
# entitlements and flags. Usage: resign.sh <identity> <path/to/VoiceInk.app>
set -euo pipefail

IDENTITY="$1"
APP="$2"

sign() {
  codesign --force --sign "$IDENTITY" --timestamp=none \
    --preserve-metadata=entitlements,flags,runtime "$1"
}

# Loose binaries first (dylibs, Sparkle's Autoupdate), then bundles from the
# deepest path up, then the app itself.
while IFS= read -r binary; do
  sign "$binary"
done < <(find "$APP/Contents" -type f \( -name "*.dylib" -o -path "*/Sparkle.framework/Versions/*/Autoupdate" \))

while IFS= read -r bundle; do
  sign "$bundle"
done < <(find "$APP/Contents" -type d \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.bundle" -o -name "*.appex" \) |
  awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-)

sign "$APP"

codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority|^Identifier"
codesign -d -r- "$APP" 2>&1 | grep designated
