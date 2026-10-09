import AppKit
import CryptoKit
import Foundation
import OSLog
import SwiftData
import SystemConfiguration

/// Keeps settings, modes, prompts, dictionary, custom models, AI provider preferences and API keys in sync
/// between Macs through iCloud Drive (one small file per section in `iCloud Drive/VoiceInk/Sync`).
///
/// Local builds cannot use CloudKit or iCloud Keychain (both need an Apple Developer provisioning profile),
/// but VoiceInk is not sandboxed, so it can read and write the user's iCloud Drive folder directly.
///
/// Every section of the file is last-writer-wins on its own: a Mac uploads a section when its local copy
/// changed since the last sync, and applies a section when another Mac uploaded a newer revision.
/// API keys are encrypted with a passphrase that never leaves the Mac (it is kept in the local Keychain).
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()

    enum SyncSection: String, CaseIterable, Sendable {
        case general
        case prompts
        case modes
        case dictionary
        case customModels
        case preferences
        case apiKeys
    }

    struct Dependencies {
        let enhancementService: AIEnhancementService
        let recordingShortcutManager: RecordingShortcutManager
        let menuBarManager: MenuBarManager
        let recorderUIManager: RecorderUIManager
        let transcriptionModelManager: TranscriptionModelManager
        let modelContext: ModelContext
    }

    struct SectionEntry: Codable, Sendable {
        var format = 1
        let revision: String
        let updatedAt: Date
        let deviceID: String
        let deviceName: String
        let appVersion: String
        let payload: Data
    }

    enum SyncError: LocalizedError {
        case iCloudDriveUnavailable

        var errorDescription: String? {
            switch self {
            case .iCloudDriveUnavailable:
                return "iCloud Drive is not turned on for this Mac (System Settings > Apple Account > iCloud > Drive)."
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var hasPassphrase: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var apiKeysMessage: String?
    @Published private(set) var needsRelaunch = false

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ICloudSync")
    private let defaults = UserDefaults.standard
    private var dependencies: Dependencies?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var syncAgain = false

    private static let syncInterval: TimeInterval = 20
    private static let enabledKey = "ICloudSync.enabled"
    private static let deviceIDKey = "ICloudSync.deviceID"
    private static let syncedRevisionsKey = "ICloudSync.syncedRevisions"
    private static let localHashesKey = "ICloudSync.localHashes"
    private static let lastSyncDateKey = "ICloudSync.lastSyncDate"
    private static let passphraseKeychainKey = "ICloudSync.apiKeyPassphrase"

    /// Preferences outside the upstream backup format. They are read when the services start,
    /// so remote changes are written to UserDefaults and take full effect on the next launch.
    private static let preferenceKeys: Set<String> = [
        "selectedAIProvider",
        "customProviderBaseURL",
        "customProviderModel",
        "customAIProviders",
        "ollamaBaseURL",
        "ollamaSelectedModel",
        "OpenRouterSelectedModel",
        "SelectedLanguage",
        "TranscriptionPrompt",
        "CustomLanguagePrompts",
        "FillerWords",
        "AppendTrailingSpace",
        "IsVADEnabled",
        "pasteMethod",
        "useAppleScriptPaste",
        "isSoundFeedbackEnabled",
        "CloudTranscriptionTimeout",
        "EnhancementTimeoutSeconds",
        "EnhancementRetryOnTimeout",
        "SkipShortEnhancement",
        "ShortEnhancementWordThreshold",
        "localCLICommandTemplate",
        "localCLISelectedTemplate",
        "localCLITimeoutSeconds",
        "ShowLiveTranscript",
        "enableAnnouncements",
        "dashboardDisplayName",
        "audioPlaybackRate",
    ]
    /// Per-provider model selections, e.g. "GroqSelectedModel" or "OpenAICustomModelID".
    private static let preferenceKeySuffixes = ["SelectedModel", "CustomModelID"]

    /// Providers whose API keys live under APIKeyManager's standard identifiers.
    private static let extraKeyProviders = ["xai", "cartesia"]

    private lazy var deviceID: String = {
        if let existing = defaults.string(forKey: Self.deviceIDKey) {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.deviceIDKey)
        return created
    }()
    private lazy var deviceName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        hasPassphrase = Self.storedPassphrase() != nil
        lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncDateKey) as? Date
    }

    // MARK: - Paths

    nonisolated static var iCloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    nonisolated static var syncFolderURL: URL {
        iCloudDriveURL
            .appendingPathComponent("VoiceInk", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
    }

    nonisolated static func fileURL(for section: SyncSection) -> URL {
        syncFolderURL.appendingPathComponent("\(section.rawValue).json")
    }

    // MARK: - Lifecycle

    /// Applies synced preferences before the services that read them are created.
    static func prepareAtLaunch() {
        let service = ICloudSyncService.shared
        guard service.isEnabled else { return }

        // Never block launch for long on iCloud Drive (e.g. offline with an evicted file).
        let semaphore = DispatchSemaphore(value: 0)
        let box = RemoteBox()
        let section = SyncSection.preferences
        DispatchQueue.global(qos: .userInitiated).async {
            box.entry = try? Self.readRemoteEntry(for: section)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2) == .success, let entry = box.entry else { return }

        guard entry.deviceID != service.deviceID,
            entry.revision != service.syncedRevisions[section.rawValue]
        else { return }

        do {
            _ = try service.applyPreferences(entry.payload)
            service.markSynced(section, revision: entry.revision, localHash: try service.preferencesSnapshot().hash)
            service.logger.info("Applied synced preferences at launch")
        } catch {
            service.logger.error("Could not apply synced preferences at launch: \(error.localizedDescription)")
        }
    }

    func start(dependencies: Dependencies) {
        self.dependencies = dependencies

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ICloudSyncService.shared.syncSoon() }
        }

        if isEnabled {
            startTimer()
            syncSoon()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)

        if enabled {
            // A fresh start: whatever another Mac already uploaded wins, then local sections fill the gaps.
            defaults.removeObject(forKey: Self.syncedRevisionsKey)
            defaults.removeObject(forKey: Self.localHashesKey)
            errorMessage = nil
            startTimer()
            syncSoon()
        } else {
            timer?.invalidate()
            timer = nil
            errorMessage = nil
            apiKeysMessage = nil
        }
    }

    func setPassphrase(_ passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainService.shared.save(trimmed, forKey: Self.passphraseKeychainKey, syncable: false)
        cachedPassphrase = .some(trimmed)
        hasPassphrase = true
        apiKeysMessage = nil
        // Re-check API keys against the remote copy with the new passphrase.
        var revisions = syncedRevisions
        revisions.removeValue(forKey: SyncSection.apiKeys.rawValue)
        defaults.set(revisions, forKey: Self.syncedRevisionsKey)
        var hashes = localHashes
        hashes.removeValue(forKey: SyncSection.apiKeys.rawValue)
        defaults.set(hashes, forKey: Self.localHashesKey)
        syncSoon()
    }

    func removePassphrase() {
        KeychainService.shared.delete(forKey: Self.passphraseKeychainKey, syncable: false)
        cachedPassphrase = .some(nil)
        hasPassphrase = false
        apiKeysMessage = nil
    }

    func syncSoon() {
        guard isEnabled, dependencies != nil else { return }
        Task { await syncNow() }
    }

    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { _ in
            Task { @MainActor in ICloudSyncService.shared.syncSoon() }
        }
    }

    // MARK: - Sync

    func syncNow() async {
        guard isEnabled, let dependencies else { return }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if syncAgain {
                syncAgain = false
                syncSoon()
            }
        }

        do {
            guard FileManager.default.fileExists(atPath: Self.iCloudDriveURL.path) else {
                throw SyncError.iCloudDriveUnavailable
            }

            let remote = try await Task.detached(priority: .utility) { try Self.readRemoteEntries() }.value

            for section in SyncSection.allCases {
                let entry = remote[section]
                let syncedRevision = syncedRevisions[section.rawValue]

                if let entry, entry.revision != syncedRevision {
                    if entry.deviceID == deviceID {
                        // Our own upload (e.g. after turning sync off and on): adopt it and let the dirty
                        // check below upload anything that changed meanwhile.
                        markSynced(
                            section, revision: entry.revision,
                            localHash: section == .apiKeys ? nil : Self.hash(entry.payload))
                    } else if try await apply(
                        section, payload: entry.payload, isFirstSync: syncedRevision == nil,
                        dependencies: dependencies)
                    {
                        let appliedHash = try await snapshot(for: section)?.hash
                        markSynced(section, revision: entry.revision, localHash: appliedHash)
                        logger.info(
                            "Applied \(section.rawValue, privacy: .public) from \(entry.deviceName, privacy: .public)")
                    }
                    continue
                }

                guard let local = try await snapshot(for: section) else { continue }
                guard entry == nil || local.hash != localHashes[section.rawValue] else { continue }

                let payload: Data
                if section == .apiKeys {
                    guard let sealed = try sealAPIKeys(local.payload, existing: entry) else { continue }
                    payload = sealed
                } else {
                    payload = local.payload
                }

                let newEntry = SectionEntry(
                    revision: UUID().uuidString,
                    updatedAt: Date(),
                    deviceID: deviceID,
                    deviceName: deviceName,
                    appVersion: appVersion,
                    payload: payload
                )
                try await Task.detached(priority: .utility) { try Self.writeRemoteEntry(newEntry, for: section) }.value
                markSynced(section, revision: newEntry.revision, localHash: local.hash)
                logger.info("Uploaded \(section.rawValue, privacy: .public)")
            }

            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: Self.lastSyncDateKey)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            logger.error("iCloud sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Bookkeeping

    private var syncedRevisions: [String: String] {
        defaults.dictionary(forKey: Self.syncedRevisionsKey) as? [String: String] ?? [:]
    }

    private var localHashes: [String: String] {
        defaults.dictionary(forKey: Self.localHashesKey) as? [String: String] ?? [:]
    }

    private func markSynced(_ section: SyncSection, revision: String, localHash: String?) {
        var revisions = syncedRevisions
        revisions[section.rawValue] = revision
        defaults.set(revisions, forKey: Self.syncedRevisionsKey)

        var hashes = localHashes
        hashes[section.rawValue] = localHash
        defaults.set(hashes, forKey: Self.localHashesKey)
    }

    // MARK: - Local snapshots

    private struct Snapshot {
        let payload: Data
        let hash: String
    }

    private func snapshot(for section: SyncSection) async throws -> Snapshot? {
        switch section {
        case .general, .prompts, .modes, .dictionary, .customModels:
            return try await backupSnapshot(for: section)
        case .preferences:
            return try preferencesSnapshot()
        case .apiKeys:
            guard hasPassphrase else { return nil }
            return try apiKeysSnapshot()
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// One upstream `BackupFile` per section, so `BackupImporter` applies it exactly like a manual import.
    private func backupSnapshot(for section: SyncSection) async throws -> Snapshot {
        let backup: BackupFile
        switch section {
        case .general:
            backup = makeBackup(generalSettings: await currentGeneralSettings())
        case .prompts:
            backup = makeBackup(customPrompts: dependencies?.enhancementService.customPrompts ?? [])
        case .modes:
            let modeConfigs = ModeManager.shared.configurations
            let modeShortcuts = Dictionary(
                uniqueKeysWithValues: modeConfigs.compactMap { config -> (String, ShortcutBackup)? in
                    guard let shortcut = ShortcutStore.shortcut(for: .mode(config.id)) else { return nil }
                    return (config.id.uuidString, ShortcutBackup(shortcut))
                })
            backup = makeBackup(
                modeConfigs: modeConfigs,
                modeShortcuts: modeShortcuts.isEmpty ? nil : modeShortcuts,
                customEmojis: EmojiManager.shared.customEmojis
            )
        case .dictionary:
            var vocabulary: [WordBackup]? = nil
            var replacements: [String: String]? = nil
            if let modelContext = dependencies?.modelContext {
                if let words = try? modelContext.fetch(FetchDescriptor<VocabularyWord>()), !words.isEmpty {
                    vocabulary = words.map(\.word).sorted().map { WordBackup(word: $0) }
                }
                if let rules = try? modelContext.fetch(FetchDescriptor<WordReplacement>(sortBy: [SortDescriptor(\.dateAdded)])), !rules.isEmpty {
                    replacements = Dictionary(
                        rules.map { ($0.originalText, $0.replacementText) }, uniquingKeysWith: { _, last in last })
                }
            }
            backup = makeBackup(vocabularyWords: vocabulary, wordReplacements: replacements)
        case .customModels:
            backup = makeBackup(
                customCloudModels: CustomCloudModelManager.shared.customModels.map { CustomModelBackup(model: $0) })
        case .preferences, .apiKeys:
            preconditionFailure("not a backup section")
        }

        let data = try Self.makeEncoder().encode(backup)
        return Snapshot(payload: data, hash: Self.hash(data))
    }

    private func makeBackup(
        customPrompts: [CustomPrompt] = [],
        modeConfigs: [ModeConfig] = [],
        modeShortcuts: [String: ShortcutBackup]? = nil,
        vocabularyWords: [WordBackup]? = nil,
        wordReplacements: [String: String]? = nil,
        generalSettings: GeneralBackup? = nil,
        customEmojis: [String]? = nil,
        customCloudModels: [CustomModelBackup]? = nil
    ) -> BackupFile {
        BackupFile(
            version: "sync",
            customPrompts: customPrompts,
            modeConfigs: modeConfigs,
            modeShortcuts: modeShortcuts,
            vocabularyWords: vocabularyWords,
            wordReplacements: wordReplacements,
            generalSettings: generalSettings,
            customEmojis: customEmojis,
            customCloudModels: customCloudModels
        )
    }

    /// Same fields as `ImportExportService.exportSettings`.
    private func currentGeneralSettings() async -> GeneralBackup? {
        guard let dependencies else { return nil }
        let recordingShortcutManager = dependencies.recordingShortcutManager
        let mediaController = MediaController.shared
        let playbackController = PlaybackController.shared
        let launchAtLoginEnabled = await LaunchAtLoginManager.shared.currentEnabledStatus()

        return GeneralBackup(
            primaryRecordingShortcut: ShortcutStore.shortcut(for: .primaryRecording).map(ShortcutBackup.init),
            secondaryRecordingShortcut: ShortcutStore.shortcut(for: .secondaryRecording).map(ShortcutBackup.init),
            pasteLastTranscriptionShortcut: ShortcutStore.shortcut(for: .pasteLastTranscription).map(
                ShortcutBackup.init),
            pasteLastEnhancementShortcut: ShortcutStore.shortcut(for: .pasteLastEnhancement).map(ShortcutBackup.init),
            retryLastTranscriptionShortcut: ShortcutStore.shortcut(for: .retryLastTranscription).map(
                ShortcutBackup.init),
            cancelRecorderShortcut: ShortcutStore.shortcut(for: .cancelRecorder).map(ShortcutBackup.init),
            openHistoryWindowShortcut: ShortcutStore.shortcut(for: .openQuickHistory).map(ShortcutBackup.init),
            quickAddToDictionaryShortcut: ShortcutStore.shortcut(for: .quickAddToDictionary).map(ShortcutBackup.init),
            primaryRecordingShortcutRawValue: recordingShortcutManager.primaryRecordingShortcut.rawValue,
            secondaryRecordingShortcutRawValue: recordingShortcutManager.secondaryRecordingShortcut.rawValue,
            primaryRecordingShortcutModeRawValue: recordingShortcutManager.primaryRecordingShortcutMode.rawValue,
            secondaryRecordingShortcutModeRawValue: recordingShortcutManager.secondaryRecordingShortcutMode.rawValue,
            launchAtLoginEnabled: launchAtLoginEnabled,
            isMenuBarOnly: dependencies.menuBarManager.isMenuBarOnly,
            recorderType: dependencies.recorderUIManager.recorderPanelStyle.rawValue,
            appAppearancePreference: AppAppearancePreference.stored.rawValue,
            appLanguagePreference: AppLanguagePreference.storedRawValue,
            isTranscriptionCleanupEnabled: defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
            transcriptionRetentionMinutes: defaults.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes),
            isAudioCleanupEnabled: defaults.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
            audioRetentionPeriod: defaults.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod),
            isSystemMuteEnabled: mediaController.isSystemMuteEnabled,
            isPauseMediaEnabled: playbackController.isPauseMediaEnabled,
            audioResumptionDelay: mediaController.audioResumptionDelay,
            isTextFormattingEnabled: defaults.bool(forKey: "IsTextFormattingEnabled"),
            isExperimentalFeaturesEnabled: defaults.bool(forKey: "isExperimentalFeaturesEnabled"),
            restoreClipboardAfterPaste: defaults.bool(forKey: "restoreClipboardAfterPaste"),
            clipboardRestoreDelay: defaults.double(forKey: "clipboardRestoreDelay"),
            finishAndSendKey: FinishAndSendSettings.selectedKey.rawValue,
            isAutoLearnDictionaryEnabled: AutoLearnSettings.isEnabled,
            autoLearnReviewSchedule: AutoLearnSettings.reviewSchedule.rawValue,
            autoLearnProvider: AutoLearnSettings.selectedProvider?.rawValue,
            autoLearnModel: AutoLearnSettings.selectedModel
        )
    }

    private func isPreferenceKey(_ key: String) -> Bool {
        Self.preferenceKeys.contains(key) || Self.preferenceKeySuffixes.contains { key.hasSuffix($0) }
    }

    private func currentPreferences() -> [String: Any] {
        let domainName = Bundle.main.bundleIdentifier ?? ""
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        return domain.filter { isPreferenceKey($0.key) }
    }

    private func preferencesSnapshot() throws -> Snapshot {
        // XML property lists write dictionary keys sorted, so equal preferences give equal hashes.
        let data = try PropertyListSerialization.data(
            fromPropertyList: currentPreferences(), format: .xml, options: 0)
        return Snapshot(payload: data, hash: Self.hash(data))
    }

    private func apiKeysSnapshot() throws -> Snapshot {
        let apiKeys = APIKeyManager.shared
        var keys: [String: String] = [:]

        let providers = Set(AIProvider.allCases.map { $0.rawValue.lowercased() } + Self.extraKeyProviders)
        for provider in providers {
            if let key = apiKeys.getAPIKey(forProvider: provider), !key.isEmpty {
                keys["provider:\(provider)"] = key
            }
        }
        for model in CustomCloudModelManager.shared.customModels {
            if let key = apiKeys.getCustomModelAPIKey(forModelId: model.id), !key.isEmpty {
                keys["customModel:\(model.id.uuidString)"] = key
            }
        }
        for provider in CustomAIProviderManager.shared.providers {
            if let key = apiKeys.getCustomAIProviderAPIKey(forProviderId: provider.id), !key.isEmpty {
                keys["customAIProvider:\(provider.id.uuidString)"] = key
            }
        }

        let data = try Self.makeEncoder().encode(keys)
        return Snapshot(payload: data, hash: Self.hash(data))
    }

    private var cachedPassphrase: String??

    private var passphrase: String? {
        if let cachedPassphrase { return cachedPassphrase }
        let value = Self.storedPassphrase()
        cachedPassphrase = .some(value)
        return value
    }

    private static func storedPassphrase() -> String? {
        guard let value = KeychainService.shared.getString(forKey: passphraseKeychainKey, syncable: false),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Returns nil (and skips the upload) when the remote keys use a different passphrase,
    /// so one Mac never locks the other out of its keys.
    private func sealAPIKeys(_ plaintext: Data, existing: SectionEntry?) throws -> Data? {
        guard let passphrase else { return nil }
        let existingSealed = existing.flatMap { try? JSONDecoder().decode(ICloudSyncCrypto.SealedPayload.self, from: $0.payload) }
        if let existingSealed, (try? ICloudSyncCrypto.open(existingSealed, passphrase: passphrase)) == nil {
            apiKeysMessage = ICloudSyncCrypto.CryptoError.wrongPassphrase.localizedDescription
            return nil
        }
        let sealed = try ICloudSyncCrypto.seal(plaintext, passphrase: passphrase, reusingSaltFrom: existingSealed)
        apiKeysMessage = nil
        return try JSONEncoder().encode(sealed)
    }

    // MARK: - Applying remote sections

    /// Returns false when the section cannot be applied yet (it stays pending and is retried).
    private func apply(
        _ section: SyncSection, payload: Data, isFirstSync: Bool, dependencies: Dependencies
    ) async throws -> Bool {
        switch section {
        case .dictionary where !isFirstSync:
            // After the first sync the remote dictionary is the whole truth, so deletions propagate.
            // The first sync merges, so turning sync on never loses words that exist only on this Mac.
            let backup = try Self.makeDecoder().decode(BackupFile.self, from: payload)
            try await replaceDictionary(with: backup, modelContext: dependencies.modelContext)
            return true

        case .general, .prompts, .modes, .dictionary, .customModels:
            let backup = try Self.makeDecoder().decode(BackupFile.self, from: payload)
            let category: BackupCategory
            switch section {
            case .general: category = .general
            case .prompts: category = .prompts
            case .modes: category = .modes
            case .dictionary: category = .dictionary
            default: category = .customModels
            }
            try await BackupImporter.apply(
                backup,
                categories: [category],
                enhancementService: dependencies.enhancementService,
                recordingShortcutManager: dependencies.recordingShortcutManager,
                menuBarManager: dependencies.menuBarManager,
                mediaController: MediaController.shared,
                playbackController: PlaybackController.shared,
                recorderUIManager: dependencies.recorderUIManager,
                modelContext: dependencies.modelContext,
                transcriptionModelManager: dependencies.transcriptionModelManager
            )
            return true

        case .preferences:
            // Running services keep these values in memory and may write them back, so they are only
            // applied at launch (prepareAtLaunch), before those services start.
            needsRelaunch = true
            return false

        case .apiKeys:
            guard let passphrase else {
                apiKeysMessage = "Your other Mac shares API keys. Enter the same passphrase to receive them."
                return false
            }
            let sealed = try JSONDecoder().decode(ICloudSyncCrypto.SealedPayload.self, from: payload)
            let plaintext: Data
            do {
                plaintext = try ICloudSyncCrypto.open(sealed, passphrase: passphrase)
            } catch {
                apiKeysMessage = error.localizedDescription
                return false
            }
            applyAPIKeys(try JSONDecoder().decode([String: String].self, from: plaintext))
            apiKeysMessage = nil
            return true
        }
    }

    private func replaceDictionary(with backup: BackupFile, modelContext: ModelContext) async throws {
        let replacements = (backup.wordReplacements ?? [:])
            .sorted { $0.key < $1.key }
            .map { original, replacement in
                DictionaryReplacementEntry(
                    sources: WordReplacementVariants.parse(original),
                    replacement: replacement,
                    createdAt: nil
                )
            }
        let vocabulary = (backup.vocabularyWords ?? []).map {
            DictionaryVocabularyEntry(term: $0.word, createdAt: nil)
        }

        if vocabulary.isEmpty && replacements.isEmpty {
            for item in try modelContext.fetch(FetchDescriptor<VocabularyWord>()) {
                modelContext.delete(item)
            }
            for item in try modelContext.fetch(FetchDescriptor<WordReplacement>()) {
                modelContext.delete(item)
            }
            try modelContext.save()
        } else {
            _ = try await DictionaryImportExportService.apply(
                archive: DictionaryArchive(vocabulary: vocabulary, replacements: replacements),
                mode: .replace,
                modelContext: modelContext
            )
        }
        DictionaryService.cleanUpDictionaryContent(context: modelContext, source: "iCloud sync")
    }

    /// Mirrors the remote preferences. Returns true when something changed.
    private func applyPreferences(_ payload: Data) throws -> Bool {
        guard
            let remote = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any]
        else { return false }

        let local = currentPreferences()
        var changed = false

        for (key, value) in remote where isPreferenceKey(key) {
            if let current = local[key] as? NSObject, let incoming = value as? NSObject, current.isEqual(incoming) {
                continue
            }
            defaults.set(value, forKey: key)
            changed = true
        }
        for key in local.keys where remote[key] == nil {
            defaults.removeObject(forKey: key)
            changed = true
        }
        return changed
    }

    /// Adds and updates keys; a key removed on one Mac is not removed from the others.
    private func applyAPIKeys(_ keys: [String: String]) {
        let apiKeys = APIKeyManager.shared
        var changed = false
        for (identifier, value) in keys where !value.isEmpty {
            let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "provider":
                if apiKeys.getAPIKey(forProvider: parts[1]) != value {
                    changed = apiKeys.saveAPIKey(value, forProvider: parts[1]) || changed
                }
            case "customModel":
                if let id = UUID(uuidString: parts[1]), apiKeys.getCustomModelAPIKey(forModelId: id) != value {
                    changed = apiKeys.saveCustomModelAPIKey(value, forModelId: id) || changed
                }
            case "customAIProvider":
                if let id = UUID(uuidString: parts[1]), apiKeys.getCustomAIProviderAPIKey(forProviderId: id) != value {
                    changed = apiKeys.saveCustomAIProviderAPIKey(value, forProviderId: id) || changed
                }
            default:
                continue
            }
        }
        if changed {
            needsRelaunch = true
        }
    }

    // MARK: - File access

    private final class RemoteBox: @unchecked Sendable {
        var entry: SectionEntry?
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func readRemoteEntries() throws -> [SyncSection: SectionEntry] {
        var entries: [SyncSection: SectionEntry] = [:]
        for section in SyncSection.allCases {
            do {
                if let entry = try readRemoteEntry(for: section) {
                    entries[section] = entry
                }
            } catch is DecodingError {
                // A file from a newer, incompatible version: leave that section alone.
                continue
            }
        }
        return entries
    }

    nonisolated private static func readRemoteEntry(for section: SyncSection) throws -> SectionEntry? {
        let url = fileURL(for: section)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try makeDecoder().decode(SectionEntry.self, from: try result.get())
    }

    nonisolated private static func writeRemoteEntry(_ entry: SectionEntry, for section: SyncSection) throws {
        let url = fileURL(for: section)
        try FileManager.default.createDirectory(at: syncFolderURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
