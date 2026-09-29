//
//  LocalShellFolders.swift
//
//  Folders the user has granted the interpreter's local shell outside its home.
//

import Foundation
import ios_system
import os

/// Security-scoped folder grants for the interpreter backend.
///
/// The interpreter's home is the app's Documents directory. Under App Sandbox
/// (the Mac App Store build) that is the only writable place it starts with; the
/// user's real folders reach the shell only through the `files.user-selected`
/// entitlement, one picker choice at a time. Each choice is kept as a
/// security-scoped bookmark, re-resolved at launch, held open for the life of
/// the process, and handed to ios_system as an allowed `cd` target so the
/// shell's own `cd` lets the user in. Nothing here grants access: the sandbox
/// does, in response to the picker.
///
/// Off Catalyst this store compiles but has no UI; the interpreter's home is
/// all it needs there.
@Observable
@MainActor
final class LocalShellFolders {
    static let shared = LocalShellFolders()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "LocalShellFolders")
    private static let defaultsKey = "localShellFolderBookmarks"

    /// Granted folders in the order they were added. Paths, not URLs, because
    /// that is what the shell and ios_system speak.
    private(set) var paths: [String] = []

    /// Bookmarks that no longer resolve, by their stored data index, so the UI
    /// can offer to forget them. A moved or deleted folder ends up here.
    private(set) var staleCount = 0

    /// URLs with `startAccessingSecurityScopedResource` in effect, kept for the
    /// life of the process: the shell may `cd` into them at any time.
    private var accessed: [URL] = []

    private init() {}

    /// Resolves every stored bookmark, starts access, and applies the result to
    /// ios_system. Call once after `initializeEnvironment()`; later changes call
    /// it again through `add`/`remove`.
    func activate() {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        accessed = []
        var resolved: [String] = []
        var stale = 0
        for data in storedBookmarks() {
            do {
                var isStale = false
                let url = try Self.resolve(data, isStale: &isStale)
                if isStale { stale += 1 }
                if url.startAccessingSecurityScopedResource() {
                    accessed.append(url)
                } else {
                    Self.logger.warning("Folder grant could not be reactivated: \(url.path, privacy: .public)")
                }
                resolved.append(url.path)
            } catch {
                stale += 1
                Self.logger.error("Folder bookmark no longer resolves: \(error.localizedDescription, privacy: .public)")
            }
        }
        paths = resolved
        staleCount = stale
        applyToIOSSystem()
    }

    /// Records a folder the user picked. The picker URL already carries the
    /// sandbox extension; the bookmark makes it survive relaunch.
    func add(_ pickerURL: URL) throws {
        let accessing = pickerURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickerURL.stopAccessingSecurityScopedResource() } }
        let data = try Self.bookmark(for: pickerURL)
        var bookmarks = storedBookmarks()
        // Re-adding a folder refreshes its bookmark instead of listing it twice.
        if let index = paths.firstIndex(of: pickerURL.path), index < bookmarks.count {
            bookmarks[index] = data
        } else {
            bookmarks.append(data)
        }
        store(bookmarks)
        activate()
    }

    /// Forgets a granted folder. Access ends at the next `activate()`, which
    /// this triggers; a shell already inside the folder keeps its descriptor
    /// until it leaves, the same as any other revoked grant.
    func remove(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        var bookmarks = storedBookmarks()
        guard index < bookmarks.count else { return }
        bookmarks.remove(at: index)
        store(bookmarks)
        activate()
    }

    /// Drops every bookmark that failed to resolve in the last `activate()`.
    func forgetStale() {
        let bookmarks = storedBookmarks().filter { data in
            var isStale = false
            guard let url = try? Self.resolve(data, isStale: &isStale) else { return false }
            return !isStale && FileManager.default.fileExists(atPath: url.path)
        }
        store(bookmarks)
        activate()
    }

    // MARK: - ios_system

    /// `ios_setAllowedPaths` is process-wide, not per session, so one call
    /// covers every open tab. ios_system keeps the array by reference.
    private func applyToIOSSystem() {
        ios_setAllowedPaths(paths)
        Self.logger.info("Allowed folders: \(self.paths.count)")
    }

    // MARK: - Bookmarks

    /// Mac Catalyst bookmarks need the security-scope option to carry the
    /// sandbox extension; iOS bookmarks are security-scoped implicitly and
    /// reject the option.
    private static func bookmark(for url: URL) throws -> Data {
        #if targetEnvironment(macCatalyst)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static func resolve(_ data: Data, isStale: inout Bool) throws -> URL {
        #if targetEnvironment(macCatalyst)
        return try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
    }

    private func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data] ?? []
    }

    private func store(_ bookmarks: [Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
    }
}
