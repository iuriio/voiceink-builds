import SwiftUI

struct ICloudSyncSettingsSection: View {
    @ObservedObject private var sync = ICloudSyncService.shared

    var body: some View {
        Section {
            Toggle(
                "Sync with iCloud Drive",
                isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })
            )

            if sync.isEnabled {
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
                "Keeps settings, modes, prompts, dictionary, custom models, AI provider choices and API keys the same on all your Macs, through the VoiceInk folder in iCloud Drive. API keys are protected by your iCloud account, like the rest of your iCloud Drive. Downloaded models and the selected transcription model stay per Mac."
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
}
