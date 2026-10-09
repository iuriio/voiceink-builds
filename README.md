# voiceink-builds

Automated builds of [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3.0) from upstream `main`, using the upstream `make local` target, with in-app updates through Sparkle.

## How it works

- `.github/workflows/build.yml` runs every 6h. If upstream `main` moved since the last build, it builds that commit on a `macos-26` runner.
- The app is **Universal** (Apple Silicon + Intel): one DMG/zip and one Sparkle feed for both. Without a generic destination `xcodebuild` only builds the runner's arch (arm64), so the workflow sets one and fails the build if any binary in the bundle lacks `arm64` or `x86_64`.
  - On Intel, VoiceInk Refine (local MLX model) is unavailable, as in upstream; transcription and everything else work.
- Before building it changes only these things in the upstream source:
  - `SUFeedURL` points to `appcast.xml` in this repo
  - `SUPublicEDKey` is this repo's Sparkle key
  - `CURRENT_PROJECT_VERSION` is a UTC timestamp, so every build is newer than the last
  - `Makefile`: `make local` gets `-destination 'generic/platform=macOS'` (Universal build)
  - [`patches/icloud-sync`](patches/icloud-sync): adds iCloud Drive sync (below). If upstream moves the code it hooks into, the build falls back to plain upstream and the release notes say so.
- The app is signed with a stable self-signed certificate (`VoiceInk Local Signing`), so macOS keeps microphone/accessibility permissions across updates.
- Each build publishes a release (`VoiceInk.zip` for Sparkle, `VoiceInk.dmg` for manual install) and commits the new `appcast.xml`. The last 10 releases are kept.
- The installed app checks `appcast.xml` and shows the update in the Dashboard / "Check for Updates…".

## iCloud Sync

Upstream syncs the dictionary through CloudKit and API keys through iCloud Keychain, but both need an Apple Developer provisioning profile, so local builds have no sync. This build adds **Settings → iCloud Sync** instead, which syncs through one small file per section in `iCloud Drive/VoiceInk/Sync/` (VoiceInk is not sandboxed, so no entitlement is needed):

- general settings and shortcuts, prompts, modes, dictionary and custom models, applied live exactly like *Import Settings*
- AI provider choices and models, Ollama/custom provider settings, language, filler words, paste and enhancement options. These are applied when the app starts; after a remote change the section offers *Relaunch*.
- API keys, encrypted with AES-GCM using a passphrase (PBKDF2-SHA256) that stays in each Mac's Keychain. Use the same passphrase on every Mac.

Each part is last-writer-wins on its own. When you turn sync on, whatever another Mac already uploaded wins. Dictionary entries and API keys are merged, so deleting one on one Mac does not delete it on the others. Downloaded models, the selected transcription model, history and license stay per Mac.

## Secrets

- `SIGNING_P12_BASE64`, `SIGNING_P12_PASSWORD`: code signing certificate
- `SPARKLE_PRIVATE_KEY`: EdDSA private key for Sparkle

Local backup: `~/.voiceink-local/signing/` and `~/.voiceink-local/sparkle/`. Do not lose them: a new certificate means granting macOS permissions again, and a new Sparkle key means installed apps reject updates (reinstall the DMG manually).

## Mac commands

```bash
voiceink-update install       # first install (or reinstall) of the latest build
voiceink-update status
voiceink-update build [ref]   # trigger a build now
```

Source for each binary: the upstream commit linked in its release notes.
