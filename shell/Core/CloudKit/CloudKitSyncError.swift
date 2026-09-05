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

    /// Schema migration required
    case migrationRequired

    /// Permission denied
    case permissionDenied

    /// Container not found
    case containerNotFound

    /// Subscription failed
    case subscriptionFailed(String)

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
        case .migrationRequired:
            return "Data migration required. Please update the app."
        case .permissionDenied:
            return "Permission denied. Check iCloud settings."
        case .containerNotFound:
            return "CloudKit container not configured."
        case .subscriptionFailed(let reason):
            return "Failed to set up sync notifications: \(reason)"
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
        case .migrationRequired:
            return "Update to the latest version of the app."
        case .permissionDenied:
            return "Enable iCloud for this app in Settings."
        case .containerNotFound:
            return "This may be a configuration issue. Please contact support."
        case .subscriptionFailed:
            return "Sync will work but changes may be delayed."
        case .invalidPayload:
            return "The change will be skipped. Try syncing again."
        case .unknown:
            return "Try again later."
        }
    }

    /// Whether this error can be retried
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .conflictResolutionFailed, .rateLimited, .unknown:
            return true
        case .accountNotAvailable, .quotaExceeded, .serverRejected,
             .migrationRequired, .permissionDenied, .containerNotFound,
             .subscriptionFailed, .invalidPayload, .notEnabled:
            return false
        }
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
