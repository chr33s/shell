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
    /// Content hash of the last record iCloud accepted for this key, and the
    /// only signal that suppresses a push: equal content means the zone already
    /// holds this value, whatever either clock says. A `lastPushedModifiedAt`
    /// companion was written beside it at every site and never read; it is not
    /// worth reviving, because requiring the stamp to match as well would only
    /// push more, and accepting it *instead* of the hash would drop a real edit
    /// whose stamp had not moved — adopting a cloud value re-stamps `modifiedAt`
    /// to that record's own, so "unchanged stamp" does not mean "unchanged value".
    var lastPushedHash: String?
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
    /// Set when an existing sidecar file could not be turned into a usable
    /// value and its bytes could not be moved aside. Saving stays off for the
    /// rest of this launch: an empty in-memory sidecar overwriting a real one
    /// silently drops every pin (device-local keys start uploading) and every
    /// `modifiedAt` (`SettingsMergeResolver` then adopts every remote value).
    private var refusesToSave = false

    /// Just the format stamp, decoded on its own so the version can be read
    /// even when the rest of the file will not decode against this build's
    /// shape. `version` stays optional so a file written before the stamp
    /// existed falls through to the ordinary decode instead of being judged.
    private nonisolated struct VersionProbe: Decodable {
        var version: Int?
    }

    /// Why an existing sidecar file did not produce a value. Distinguishes
    /// "unreadable bytes" from "no file at all" — a fresh install must still
    /// be allowed to save.
    private enum LoadFailure {
        /// The file exists but its bytes could not be read at all; they may
        /// still be intact, so the file is left exactly where it is.
        case unreadable
        /// The bytes were read but are not a decodable sidecar.
        case undecodable
        /// The bytes decoded but carry a `version` newer than this build
        /// writes. They are a *newer* build's state, not damage, so they are
        /// left exactly where they are.
        case futureVersion
    }

    init() {
        let (loaded, failure) = Self.load()
        sidecar = loaded
        guard let failure else { return }
        switch failure {
        case .undecodable:
            // Move the garbage bytes aside *before* any mutate() can schedule
            // a save over them, so the original file survives for manual
            // recovery. If the rename fails, refuse to save instead.
            let url = Self.fileURL
            let quarantined = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: url, to: quarantined)
                Self.logger.fault(
                    "Quarantined undecodable sidecar as \(quarantined.lastPathComponent)")
            } catch {
                refusesToSave = true
                Self.logger.fault(
                    "Could not quarantine undecodable sidecar (\(error.localizedDescription)); sidecar saving disabled for this launch"
                )
            }
        case .unreadable:
            refusesToSave = true
            Self.logger.fault("Sidecar file unreadable; sidecar saving disabled for this launch")
        case .futureVersion:
            // Same treatment as unreadable, and for the same reason: the bytes
            // on disk are worth more than this launch's empty sidecar. A user
            // who runs a newer build, then this one, then the newer one again
            // gets their pins and timestamps back intact.
            refusesToSave = true
            Self.logger.fault(
                "Sidecar was written by a newer build; sidecar saving disabled for this launch")
        }
    }

    private static func load() -> (SettingsSyncSidecar, LoadFailure?) {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (SettingsSyncSidecar(), nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.fault("Failed to read sidecar file: \(error.localizedDescription)")
            return (SettingsSyncSidecar(), .unreadable)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The stamp is only worth writing if it is checked, and it has to be
        // checked *before* the full decode. Decoding a future sidecar as if it
        // were this version is one silent failure — `Codable` ignores fields it
        // does not know, so a build that changed pin semantics would come back
        // as "no pins" and this launch would start uploading device-local keys.
        // Failing that decode is the other: a property the newer build added is
        // a `keyNotFound` here, which would quarantine a newer build's state as
        // if it were damage. Reading the stamp alone catches both.
        if let probe = try? decoder.decode(VersionProbe.self, from: data),
           let version = probe.version, version > SettingsSyncSidecar.currentVersion {
            logger.fault(
                "Sidecar version \(version) is newer than \(SettingsSyncSidecar.currentVersion); starting empty"
            )
            return (SettingsSyncSidecar(), .futureVersion)
        }
        do {
            let decoded = try decoder.decode(SettingsSyncSidecar.self, from: data)
            guard decoded.version <= SettingsSyncSidecar.currentVersion else {
                logger.fault(
                    "Sidecar version \(decoded.version) is newer than \(SettingsSyncSidecar.currentVersion); starting empty"
                )
                return (SettingsSyncSidecar(), .futureVersion)
            }
            // Nothing below `currentVersion` has ever been written, so a lower
            // stamp is a damaged or hand-edited file rather than an old one.
            // When a version 2 ships, migrate here instead of rejecting.
            guard decoded.version == SettingsSyncSidecar.currentVersion else {
                logger.fault(
                    "Sidecar version \(decoded.version) predates any shipped format; starting empty")
                return (SettingsSyncSidecar(), .undecodable)
            }
            return (decoded, nil)
        } catch {
            logger.fault("Failed to decode sidecar, starting empty: \(error.localizedDescription)")
            return (SettingsSyncSidecar(), .undecodable)
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
        // Fail closed: an unreadable-but-present file that could not be
        // quarantined must never be replaced by this launch's empty sidecar.
        guard !refusesToSave else {
            Self.logger.fault("Refusing to overwrite unreadable sidecar file")
            return
        }
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
