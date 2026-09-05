//
//  SettingsMergeResolver.swift
//  shell
//
//  Pure per-key last-writer-wins with clock-skew tolerance and a
//  deterministic tie-break so every device converges on the same value.
//

import Foundation

nonisolated enum SettingsMergeResolver {
    struct Local: Sendable {
        let value: CodableValue?
        /// Nil when the value predates the sidecar.
        let modifiedAt: Date?
        let deviceID: String?
    }

    struct Remote: Sendable {
        let value: CodableValue?
        let modifiedAt: Date
        let deviceID: String
    }

    enum Decision: Sendable, Equatable {
        case applyRemote
        case keepLocal
        case keepLocalAndPush
        case noop
    }

    /// Only edits this close together count as a tie. Wider windows collapse
    /// consecutive edits from one device into ties that the tie-break then rejects.
    static let skewTolerance: TimeInterval = 2

    static func resolve(local: Local, remote: Remote, alreadyPushed: Bool) -> Decision {
        if local.value == remote.value { return .noop }
        guard let localDate = local.modifiedAt else { return .applyRemote }
        // Same author on both sides means the same clock: newest wins outright.
        if let localDevice = local.deviceID, localDevice == remote.deviceID {
            if remote.modifiedAt > localDate { return .applyRemote }
            return alreadyPushed ? .keepLocal : .keepLocalAndPush
        }
        if remote.modifiedAt > localDate + skewTolerance { return .applyRemote }
        if localDate > remote.modifiedAt + skewTolerance { return alreadyPushed ? .keepLocal : .keepLocalAndPush }
        // Near-simultaneous: lowest device ID wins on every device.
        let localDevice = local.deviceID ?? ""
        if remote.deviceID < localDevice { return .applyRemote }
        return alreadyPushed ? .keepLocal : .keepLocalAndPush
    }
}
