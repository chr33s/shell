//
//  RecoveryDescriptorStore.swift
//  shell
//
//  Versioned, device-local persistence of recovery intent
//  (spec.connectivity.md §13, §14, CON-10).
//
//  What is stored is *intent*, not a connection: no tasks, no channels, no
//  key material, no Ghostty pointers, and no terminal contents. A cold launch
//  restores a descriptor and an offer to reconnect — never a transport, and
//  never an assumption of readiness.
//
//  These records never enter CloudKit or iCloud Keychain sync. They are
//  written to the app container as a plain file rather than to the settings
//  registry precisely so there is no path by which the sync engine can pick
//  them up.
//

import Foundation
import os

/// One persisted logical session's recovery intent.
struct RecoveryDescriptor: Codable, Equatable, Sendable {
    /// Bumped whenever the shape changes. An unknown version is discarded
    /// rather than guessed at (AC-22).
    static let currentVersion = 1

    var version: Int = RecoveryDescriptor.currentVersion
    var logicalSessionID: UUID
    var intentRawValue: String
    var target: RecoveryTargetIdentity
    var tmuxEvidence: TmuxContinuityEvidence?
    /// Wall-clock time, for presentation only. Retry arithmetic never uses it.
    var updatedAt: Date
    /// Local tab identity so a restored descriptor lands on the right tab.
    var tabID: UUID?

    var intent: RecoveryIntent? {
        switch intentRawValue {
        case "attachExistingTmux": return .attachExistingTmux
        case "interactiveShell": return .interactiveShell
        case "oneShotCommand": return .oneShotCommand
        default: return nil
        }
    }

    init(
        logicalSessionID: UUID,
        intent: RecoveryIntent,
        target: RecoveryTargetIdentity,
        tmuxEvidence: TmuxContinuityEvidence?,
        tabID: UUID?,
        updatedAt: Date = Date()
    ) {
        self.logicalSessionID = logicalSessionID
        switch intent {
        case .attachExistingTmux: self.intentRawValue = "attachExistingTmux"
        case .interactiveShell: self.intentRawValue = "interactiveShell"
        case .oneShotCommand: self.intentRawValue = "oneShotCommand"
        }
        self.target = target
        self.tmuxEvidence = tmuxEvidence
        self.tabID = tabID
        self.updatedAt = updatedAt
    }

    /// Whether this record can drive an automatic reattachment at all.
    ///
    /// A one-shot command is never re-dispatched from a descriptor, including
    /// after app relaunch (AC-15). Legacy or name-only tmux state cannot
    /// establish continuity and requires explicit selection (§9.1).
    var supportsAutomaticReattach: Bool {
        guard version == RecoveryDescriptor.currentVersion else { return false }
        guard let intent else { return false }
        switch intent {
        case .oneShotCommand:
            return false
        case .interactiveShell:
            return true
        case .attachExistingTmux:
            return tmuxEvidence?.isSufficientForContinuity == true
        }
    }
}

/// Device-local descriptor storage.
///
/// Writes happen at intent changes and safe checkpoints, not only on the
/// background callback: the process can be terminated without one (§13).
@MainActor
final class RecoveryDescriptorStore {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "RecoveryDescriptors")

    static let shared = RecoveryDescriptorStore()

    private let fileURL: URL
    private var cache: [UUID: RecoveryDescriptor] = [:]
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = support.appendingPathComponent("recovery-descriptors.json")
        }
    }

    // MARK: - Access

    func descriptor(for logicalSessionID: UUID) -> RecoveryDescriptor? {
        loadIfNeeded()
        guard let descriptor = cache[logicalSessionID] else { return nil }
        // Validate before use: a record from a newer build (or a corrupted
        // one) must not be acted on.
        guard descriptor.version == RecoveryDescriptor.currentVersion,
              descriptor.intent != nil else {
            cache.removeValue(forKey: logicalSessionID)
            persist()
            return nil
        }
        return descriptor
    }

    func allDescriptors() -> [RecoveryDescriptor] {
        loadIfNeeded()
        return cache.values
            .filter { $0.version == RecoveryDescriptor.currentVersion && $0.intent != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ descriptor: RecoveryDescriptor) {
        loadIfNeeded()
        cache[descriptor.logicalSessionID] = descriptor
        prune()
        persist()
    }

    /// Save only when something a recovery would act on actually changed.
    ///
    /// The checkpoint runs on every session setup, including each reconnect
    /// attempt. Re-encoding and rewriting the whole file each time would put
    /// a synchronous disk write on the main actor in the middle of recovery,
    /// for a record that is usually identical.
    func saveIfChanged(_ descriptor: RecoveryDescriptor) {
        loadIfNeeded()
        if let existing = cache[descriptor.logicalSessionID],
           existing.intentRawValue == descriptor.intentRawValue,
           existing.target == descriptor.target,
           existing.tmuxEvidence == descriptor.tmuxEvidence,
           existing.tabID == descriptor.tabID {
            return
        }
        save(descriptor)
    }

    /// Descriptors describe live intent, so the store is small by nature. This
    /// is the backstop for the case it is not: a device that accumulated
    /// records from crashed sessions keeps the most recent ones and drops the
    /// rest, rather than growing without bound (CON-08).
    private func prune() {
        guard cache.count > Self.maxDescriptors else { return }
        let keep = cache.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maxDescriptors)
        cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.logicalSessionID, $0) })
    }

    private static let maxDescriptors = 64

    func remove(logicalSessionID: UUID) {
        loadIfNeeded()
        guard cache.removeValue(forKey: logicalSessionID) != nil else { return }
        persist()
    }

    func removeAll() {
        cache.removeAll()
        persist()
    }

    // MARK: - Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([RecoveryDescriptor].self, from: data)
            // Unknown versions are dropped rather than migrated destructively.
            for descriptor in decoded where descriptor.version == RecoveryDescriptor.currentVersion {
                cache[descriptor.logicalSessionID] = descriptor
            }
        } catch {
            Self.logger.warning("Discarding unreadable recovery descriptors: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let values = Array(cache.values)
        do {
            let data = try JSONEncoder().encode(values)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            Self.logger.warning("Failed to persist recovery descriptors: \(error.localizedDescription)")
        }
    }
}
