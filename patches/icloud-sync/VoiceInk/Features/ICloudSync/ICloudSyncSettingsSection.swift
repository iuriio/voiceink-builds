import SwiftUI

struct ICloudSyncSettingsSection: View {
    @ObservedObject private var sync = ICloudSyncService.shared
    @State private var passphraseInput = ""
    @State private var isEditingPassphrase = false

    private static let minimumPassphraseLength = 8

    var body: some View {
        Section {
            Toggle(
                "Sync with iCloud Drive",
                isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })
            )

            if sync.isEnabled {
                LabeledContent("API Key Passphrase") {
                    if sync.hasPassphrase && !isEditingPassphrase {
                        HStack(spacing: 8) {
                            Text("Set")
                                .foregroundStyle(.secondary)
                            Button("Change") { isEditingPassphrase = true }
                            Button("Remove", role: .destructive) { sync.removePassphrase() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            SecureField("At least 8 characters", text: $passphraseInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit(savePassphrase)
                            Button("Save", action: savePassphrase)
                                .disabled(passphraseInput.count < Self.minimumPassphraseLength)
                            if isEditingPassphrase {
                                Button("Cancel") {
                                    passphraseInput = ""
                                    isEditingPassphrase = false
                                }
                            }
                        }
                    }
                }

                if let apiKeysMessage = sync.apiKeysMessage {
                    Text(apiKeysMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if sync.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusText)
                            .foregroundStyle(sync.errorMessage == nil ? Color.secondary : Color.red)
                            .multilineTextAlignment(.trailing)
                        Button("Sync Now") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(sync.isSyncing)
                    }
                }

                if sync.needsRelaunch {
                    LabeledContent("Some synced changes apply after relaunching VoiceInk") {
                        Button("Relaunch") { sync.relaunch() }
                    }
                }
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text(
                "Keeps settings, modes, prompts, dictionary, custom models, AI provider choices and API keys the same on all your Macs, through the VoiceInk folder in iCloud Drive. API keys are encrypted with the passphrase; use the same one on every Mac. Downloaded models and the selected transcription model stay per Mac."
            )
        }
    }

    private var statusText: String {
        if let errorMessage = sync.errorMessage {
            return errorMessage
        }
        guard let lastSyncDate = sync.lastSyncDate else {
            return "Not synced yet"
        }
        return "Synced \(lastSyncDate.formatted(.relative(presentation: .named)))"
    }

    private func savePassphrase() {
        guard passphraseInput.count >= Self.minimumPassphraseLength else { return }
        sync.setPassphrase(passphraseInput)
        passphraseInput = ""
        isEditingPassphrase = false
    }
}
