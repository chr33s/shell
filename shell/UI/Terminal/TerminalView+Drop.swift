//
//  TerminalView+Drop.swift
//  shell
//
//  File drag-and-drop support for terminal view.
//  Matches macOS Ghostty behavior: files/URLs are shell-escaped, plain text is inserted as-is.
//

import UIKit
import UniformTypeIdentifiers
import os

// MARK: - UIDropInteractionDelegate

extension Ghostty.TerminalView: UIDropInteractionDelegate {

    /// Accepted drop types matching macOS Ghostty behavior:
    /// - File URLs: Paths are shell-escaped and inserted
    /// - URLs: Escaped as-is (useful for curl, wget, etc.)
    /// - Plain text: Inserted without escaping (for commands)
    /// - Images: Written to a temp file, path inserted
    static let acceptedDropTypes: [UTType] = [
        TabTransferCoordinator.dragUTType,
        .fileURL,
        .url,
        .plainText,
        .image
    ]

    /// Finder node type used on Mac Catalyst when dragging files from Finder
    static let finderNodeType = "com.apple.finder.node"

    // MARK: - Delegate Methods

    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, accept drops with Finder nodes or standard types
        // Finder provides com.apple.finder.node instead of public.file-url
        return session.hasItemsConforming(toTypeIdentifiers: [Self.finderNodeType]) ||
               session.hasItemsConforming(toTypeIdentifiers: Self.acceptedDropTypes.map(\.identifier))
        #else
        // Accept if session contains any of our supported types
        return session.hasItemsConforming(toTypeIdentifiers: Self.acceptedDropTypes.map(\.identifier))
        #endif
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        // A tab-transfer session must resolve here and NOT fall through to the
        // generic .copy proposal: `performDrop` can only ever hand it to
        // `receiveActiveDrag`, which refuses a same-window drag. Falling through
        // promised a copy the drop could never perform (preview animated into the
        // terminal, nothing happened). `.cancel` gives the plain no-drop cursor
        // and the snap-back animation.
        if session.hasItemsConforming(toTypeIdentifiers: [TabTransferCoordinator.dragUTType.identifier]) {
            return UIDropProposal(
                operation: TabTransferCoordinator.shared.canAcceptActiveDrag(in: windowId) ? .move : .cancel
            )
        }
        // Use .copy to show the proper drop cursor (green + icon)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        // Process items in priority order matching macOS:
        // 1. File URLs (paths escaped individually, joined by space)
        // 2. URLs (escaped as-is)
        // 3. Image data (e.g. screenshot preview thumbnails) — written to a temp
        //    file, path inserted so the running program (e.g. Claude Code) can read it
        // 4. Plain text (not escaped)

        let itemProviders = session.items.map(\.itemProvider)

        // Log the offered types so drops that "do nothing" are diagnosable.
        let typeSummary = itemProviders
            .map { $0.registeredTypeIdentifiers.joined(separator: "|") }
            .joined(separator: " ; ")
        Ghostty.logger.info("performDrop offered types: \(typeSummary)")

        if session.hasItemsConforming(toTypeIdentifiers: [TabTransferCoordinator.dragUTType.identifier]),
           TabTransferCoordinator.shared.receiveActiveDrag(
               in: windowId,
               insertionIndex: tabTransferInsertionIndex(),
               groupOverride: tabTransferGroupOverride(),
               isDestinationWindowFocused: true
           ) {
            return
        }

        let imageProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        // Route dropped images. Used directly for image-only drops, and as a
        // fallback when a file-URL / Finder-node drop resolves to nothing — a
        // screenshot preview thumbnail commonly offers only image data and/or a
        // *promised* file rather than a concrete on-disk file URL.
        let handleImages: () -> Void = { [weak self] in
            guard let self, !imageProviders.isEmpty else { return }
            self.loadImagesForLocalInsertion(from: imageProviders)
        }

        // Try file URLs first
        let fileProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            loadFileURLs(from: fileProviders, fallback: handleImages)
            return
        }

        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, Finder provides com.apple.finder.node instead of public.file-url
        let finderProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(Self.finderNodeType) }
        if !finderProviders.isEmpty {
            loadFinderNodes(from: finderProviders, fallback: handleImages)
            return
        }
        #endif

        // Try regular URLs next
        let urlProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        if !urlProviders.isEmpty {
            loadURLs(from: urlProviders)
            return
        }

        // Dropped image with no usable file URL (e.g. screenshot preview thumbnail)
        if !imageProviders.isEmpty {
            handleImages()
            return
        }

        // Fall back to plain text
        let textProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        if !textProviders.isEmpty {
            loadPlainText(from: textProviders)
            return
        }
    }

    // MARK: - Item Loading

    private func tabTransferInsertionIndex() -> Int? {
        guard let model = TerminalWindowRegistry.tabsModel(for: windowId) else { return nil }
        return model.selectedTabID
            .flatMap { model.index(of: $0) }
            .map { $0 + 1 }
    }

    private func tabTransferGroupOverride() -> TabGroupID? {
        guard let model = TerminalWindowRegistry.tabsModel(for: windowId),
              model.isGroupedModeEnabled else { return nil }
        return model.activeGroupID
    }

    /// Load file URLs, escape paths, and insert into terminal.
    /// `fallback` runs on the main queue when no file URL could be resolved
    /// (e.g. a screenshot thumbnail that only offers a promised file).
    private func loadFileURLs(from providers: [NSItemProvider], fallback: (() -> Void)? = nil) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()

            // Try the modern loadObject API first (works better on Mac Catalyst)
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    defer { group.leave() }
                    guard error == nil, let url = url else { return }

                    let escapedPath = Ghostty.Shell.escape(url.path)
                    lock.lock()
                    paths.append(escapedPath)
                    lock.unlock()
                }
            } else {
                // Fall back to loadItem for older API
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    guard error == nil else { return }

                    // Handle different representations
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let urlItem = item as? URL {
                        url = urlItem
                    } else if let string = item as? String {
                        url = URL(fileURLWithPath: string)
                    } else {
                        url = nil
                    }

                    if let url = url {
                        let escapedPath = Ghostty.Shell.escape(url.path)
                        lock.lock()
                        paths.append(escapedPath)
                        lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !paths.isEmpty else {
                // Nothing resolved (e.g. screenshot promised file) — try image data.
                fallback?()
                return
            }
            let content = paths.joined(separator: " ")
            self?.insertDroppedContent(content)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Load Finder node items (Mac Catalyst specific)
    /// Finder provides com.apple.finder.node which contains the file URL.
    /// `fallback` runs on the main queue when no node could be resolved.
    private func loadFinderNodes(from providers: [NSItemProvider], fallback: (() -> Void)? = nil) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()

            provider.loadItem(forTypeIdentifier: Self.finderNodeType, options: nil) { item, error in
                defer { group.leave() }
                guard error == nil else { return }

                // Extract URL from various representations
                let url: URL?
                if let urlItem = item as? URL {
                    url = urlItem
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                } else {
                    url = nil
                }

                if let url = url {
                    let escapedPath = Ghostty.Shell.escape(url.path)
                    lock.lock()
                    paths.append(escapedPath)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !paths.isEmpty else {
                // Nothing resolved — try image data (e.g. screenshot thumbnail).
                fallback?()
                return
            }
            let content = paths.joined(separator: " ")
            self?.insertDroppedContent(content)
        }
    }
    #endif

    /// Load URLs, escape them, and insert into terminal
    private func loadURLs(from providers: [NSItemProvider]) {
        // Just use the first URL
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            guard error == nil else {
                Ghostty.logger.warning("Failed to load URL: \(error!.localizedDescription)")
                return
            }

            let urlString: String?
            if let url = item as? URL {
                urlString = url.absoluteString
            } else if let string = item as? String {
                urlString = string
            } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urlString = url.absoluteString
            } else {
                urlString = nil
            }

            if let urlString = urlString {
                let escaped = Ghostty.Shell.escape(urlString)
                DispatchQueue.main.async {
                    self?.insertDroppedContent(escaped)
                }
            }
        }
    }

    /// Load plain text and insert as-is (no escaping, for commands)
    private func loadPlainText(from providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, error in
            guard error == nil else {
                Ghostty.logger.warning("Failed to load text: \(error!.localizedDescription)")
                return
            }

            let text: String?
            if let string = item as? String {
                text = string
            } else if let data = item as? Data {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }

            if let text = text {
                DispatchQueue.main.async {
                    // Plain text is not escaped - user may be pasting a command
                    self?.insertDroppedContent(text)
                }
            }
        }
    }

    // MARK: - Image Insertion for Local Sessions

    /// Write dropped image data to a temporary file and insert its path into the
    /// terminal. Used for local (non-SSH) sessions where a dragged image — most
    /// commonly a screenshot preview thumbnail — arrives as image data (or a
    /// promised file) rather than a concrete on-disk file URL. Writing to our own
    /// temp directory guarantees the inserted path is readable by the shell's
    /// child processes (e.g. Claude Code), and `insertDroppedContent` delivers it
    /// as a bracketed paste so the running program detects it as an image. This
    /// mirrors native macOS Ghostty, where a dragged screenshot inserts a path.
    private func loadImagesForLocalInsertion(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()
        let tmpDir = FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        for provider in providers {
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                defer { group.leave() }
                guard error == nil,
                      let image = image as? UIImage,
                      let data = image.pngData() else {
                    if let error = error {
                        Ghostty.logger.warning("Failed to load dropped image: \(error.localizedDescription)")
                    }
                    return
                }

                // Append a UUID so quick successive drops (same second) never
                // collide and overwrite a file whose path was already inserted.
                let unique = UUID().uuidString.prefix(8)
                let fileURL = tmpDir.appendingPathComponent("dropped-image-\(stamp)-\(unique).png")
                do {
                    try data.write(to: fileURL, options: .atomic)
                    let escapedPath = Ghostty.Shell.escape(fileURL.path)
                    lock.lock()
                    paths.append(escapedPath)
                    lock.unlock()
                } catch {
                    Ghostty.logger.warning("Failed to write dropped image to temp file: \(error.localizedDescription)")
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !paths.isEmpty else { return }
            let content = paths.joined(separator: " ")
            self?.insertDroppedContent(content)
        }
    }

    // MARK: - Content Insertion

    /// Insert dropped content into the terminal
    private func insertDroppedContent(_ content: String) {
        guard insertPastedText(content, recordHistory: false) else {
            Ghostty.logger.warning("Dropped content but surface is nil or content is empty")
            return
        }
        Ghostty.logger.info("Dropped content inserted via surface text: \(content.prefix(50))...")
    }
}
