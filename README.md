# voiceink-builds

Automated builds of [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3.0) from upstream `main`, using the upstream `make local` target, with in-app updates through Sparkle.

## How it works

- `.github/workflows/build.yml` runs every 6h. If upstream `main` moved since the last build, it builds that commit on a `macos-26` runner.
- Before building it changes only three things in the upstream source:
  - `SUFeedURL` points to `appcast.xml` in this repo
  - `SUPublicEDKey` is this repo's Sparkle key
  - `CURRENT_PROJECT_VERSION` is a UTC timestamp, so every build is newer than the last
- The app is signed with a stable self-signed certificate (`VoiceInk Local Signing`), so macOS keeps microphone/accessibility permissions across updates.
- Each build publishes a release (`VoiceInk.zip` for Sparkle, `VoiceInk.dmg` for manual install) and commits the new `appcast.xml`. The last 10 releases are kept.
- The installed app checks `appcast.xml` and shows the update in the Dashboard / "Check for Updates…".

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
