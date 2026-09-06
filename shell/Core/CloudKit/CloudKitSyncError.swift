//
//  CloudKitSyncError.swift
//  shell
//
//  Error types for CloudKit sync operations
//

import Foundation
import CloudKit

/// Errors that can occur during CloudKit sync
enum CloudKitSyncError: LocalizedError, Sendable {
    /// iCloud account not available or not signed in
    case accountNotAvailable

    /// Network is unavailable
    case networkUnavailable

    /// CloudKit quota exceeded
    case quotaExceeded

    /// Server rejected the operation
    case serverRejected(String)

    /// Conflict resolution failed
    case conflictResolutionFailed

    /// Permission denied
    case permissionDenied

    /// Invalid or unreadable pending change payload
    case invalidPayload(String)

    /// Request rate limited by CloudKit
    case rateLimited(retryAfter: TimeInterval)

    /// A per-type toggle was used while master sync is off
    case notEnabled

    /// Unknown error
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Enable iCloud Sync first."
        case .accountNotAvailable:
            return "iCloud account not available. Please sign in to iCloud in Settings."
        case .networkUnavailable:
            return "Network connection unavailable. Changes will sync when online."
        case .quotaExceeded:
            return "iCloud storage quota exceeded. Free up space or upgrade your plan."
        case .rateLimited(let retryAfter):
            return "CloudKit rate limited. Retry after \(Int(retryAfter)) seconds."
        case .serverRejected(let reason):
            return "Server rejected the request: \(reason)"
        case .conflictResolutionFailed:
            return "Failed to resolve sync conflict."
        case .permissionDenied:
            return "Permission denied. Check iCloud settings."
        case .invalidPayload(let reason):
            return "Invalid sync payload: \(reason)"
        case .unknown(let error):
            return "Sync error: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notEnabled:
            return "Turn on the iCloud Sync switch, then try again."
        case .accountNotAvailable:
            return "Go to Settings > Apple Account > iCloud and sign in."
        case .networkUnavailable:
            return "Check your network connection and try again."
        case .quotaExceeded:
            return "Manage your iCloud storage in Settings > Apple Account > iCloud > Manage Storage."
        case .rateLimited:
            return "CloudKit is temporarily throttling requests. The sync will retry automatically."
        case .serverRejected:
            return "Try again later or contact support if the issue persists."
        case .conflictResolutionFailed:
            return "The sync will retry automatically."
        case .permissionDenied:
            return "Enable iCloud for this app in Settings."
        case .invalidPayload:
            return "The change will be skipped. Try syncing again."
        case .unknown:
            return "Try again later."
        }
    }

    /// The diagnosis and its authored next step, as one block of user-facing text.
    ///
    /// `errorDescription` says what broke; `recoverySuggestion` says what the
    /// user has to do about it, and that half is the one that matters — "iCloud
    /// storage quota exceeded" without "Manage your iCloud storage in
    /// Settings > Apple Account > iCloud > Manage Storage" leaves a user with a
    /// diagnosis and no way out. Settings ▸ Sync surfaces errors as one plain
    /// string, so the two lines are composed here rather than in the view, and
    /// every `catch` site can hand this whatever it caught: a
    /// `CloudKitSyncError`, a raw `CKError` (mapped through `from(_:)` so it
    /// gets a suggestion too), or anything else, which falls back to its own
    /// description.
    static func userFacingMessage(for error: Error) -> String {
        let localized: LocalizedError?
        if let syncError = error as? CloudKitSyncError {
            localized = syncError
        } else if let ckError = error as? CKError {
            localized = CloudKitSyncError.from(ckError)
        } else {
            localized = error as? LocalizedError
        }
        let message = localized?.errorDescription ?? error.localizedDescription
        guard let suggestion = localized?.recoverySuggestion, !suggestion.isEmpty else {
            return message
        }
        return "\(message)\n\n\(suggestion)"
    }

    /// Create from CKError
    static func from(_ ckError: CKError) -> CloudKitSyncError {
        switch ckError.code {
        case .notAuthenticated:
            return .accountNotAvailable
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .quotaExceeded:
            return .quotaExceeded
        case .requestRateLimited:
            let retryAfter = ckError.retryAfterSeconds ?? 30
            return .rateLimited(retryAfter: retryAfter)
        case .serverRejectedRequest:
            return .serverRejected(ckError.localizedDescription)
        case .permissionFailure:
            return .permissionDenied
        case .serverRecordChanged:
            return .conflictResolutionFailed
        default:
            return .unknown(ckError)
        }
    }
}
