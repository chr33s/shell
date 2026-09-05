//
//  SettingsSyncSidecar.swift
//  shell
//
//  Per-key sync metadata and device-local pins, kept in a file rather than
//  UserDefaults so it survives locked-device empty reads and never appears
//  in domain scans.
//

import Foundation
import os

nonisolated struct SettingSyncMeta: Codable, Sendable, Equatable {
    /// Nil means the value predates the sidecar (unknown age).
    var modifiedAt: Date?
    var deviceID: String?
    var lastPushedHash: String?
    var lastPushedModifiedAt: Date?
    var shadowCloud: ShadowValue?
}

/// A cloud value retained while the key is pinned, so unpinning can adopt it.
nonisolated struct ShadowValue: Codable, Sendable, Equatable {
    var payload: CodableValue?
    var modifiedAt: Date
    var deviceID: String
}

nonisolated struct SettingsSyncSidecar: Codable, Sendable {
    static let currentVersion = 1

    var version = SettingsSyncSidecar.currentVersion
    var meta: [String: SettingSyncMeta] = [:]
    /// Explicit pins on `.synced` keys.
    var pinnedKeys: Set<String> = []
    /// Opt-outs for `.localByDefault` keys the user chose to sync.
    var unpinnedKeys: Set<String> = []
    var pinnedGroups: Set<SettingGroup> = []
    var initialMergeCompleted = false
    var accountIdentity: String?
    /// Remote values received while protected data was unavailable.
    var deferredRemote: [String: ShadowValue] = [:]
}

/// Atomic JSON persistence with a short write debounce.
@MainActor
final class SettingsSyncSidecarStore {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsSyncSidecar")

    static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("settings_sync_state.json")
    }

    private(set) var sidecar: SettingsSyncSidecar
    private var saveTask: Task<Void, Never>?

    init() {
        sidecar = Self.load()
    }

    private static func load() -> SettingsSyncSidecar {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsSyncSidecar() }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SettingsSyncSidecar.self, from: data)
        } catch {
            logger.error("Failed to read sidecar, starting empty: \(error.localizedDescription)")
            return SettingsSyncSidecar()
        }
    }

    func mutate(_ body: (inout SettingsSyncSidecar) -> Void) {
        body(&sidecar)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = sidecar
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to write sidecar: \(error.localizedDescription)")
        }
    }
}
