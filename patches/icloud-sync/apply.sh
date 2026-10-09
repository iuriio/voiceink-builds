#!/bin/bash
# Adds iCloud Drive sync to an upstream VoiceInk checkout.
# Usage: patches/icloud-sync/apply.sh <upstream-dir>
# New Swift files are picked up automatically (the VoiceInk folder is a synchronized group);
# three one-line hooks are inserted into upstream files, each checked so a moved anchor fails loudly.
set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="$1"

fail() { echo "icloud-sync: $*" >&2; exit 1; }

cp -R "$PATCH_DIR/VoiceInk/." "$UPSTREAM/VoiceInk/"

APP="$UPSTREAM/VoiceInk/App/VoiceInk.swift"
SETTINGS="$UPSTREAM/VoiceInk/Features/Settings/Views/SettingsView.swift"

# 1. Apply synced preferences before AIService and friends read them.
perl -0pi -e 's/^([ \t]*)(AppDefaults\.registerDefaults\(\)\n)/$1$2$1ICloudSyncService.prepareAtLaunch()\n/m' "$APP"
grep -q "ICloudSyncService.prepareAtLaunch()" "$APP" || fail "anchor AppDefaults.registerDefaults() not found"

# 2. Start syncing once every service exists.
perl -0pi -e 's/^([ \t]*)(AppShortcuts\.updateAppShortcutParameters\(\)\n)/$1$2\n$1ICloudSyncService.shared.start(\n$1    dependencies: ICloudSyncService.Dependencies(\n$1        enhancementService: enhancementService,\n$1        recordingShortcutManager: recordingShortcutManager,\n$1        menuBarManager: menuBarManager,\n$1        recorderUIManager: recorderUIManager,\n$1        transcriptionModelManager: transcriptionModelManager,\n$1        modelContext: resolvedContainer.mainContext))\n/m' "$APP"
grep -q "ICloudSyncService.shared.start(" "$APP" || fail "anchor AppShortcuts.updateAppShortcutParameters() not found"

# 3. Settings section, right above "Backup" (Export/Import Settings).
perl -0pi -e 's/^([ \t]*)(Section \{\n\s*LabeledContent\("Export Settings"\))/$1ICloudSyncSettingsSection()\n\n$1$2/m' "$SETTINGS"
grep -q "ICloudSyncSettingsSection()" "$SETTINGS" || fail "anchor Export Settings section not found"

echo "icloud-sync: applied"
