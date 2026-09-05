#if targetEnvironment(macCatalyst)
import Foundation
import os

@MainActor
enum MacSupport {
    /// Keep the bundle alive for the lifetime of its implementation and AppKit views.
    private static var bundle: Bundle?
    static let bridge: (any MacBridge)? = {
        let logger = Logger(subsystem: "dev.chr33s.shell", category: "MacSupport")
        guard let directory = Bundle.main.builtInPlugInsURL,
              let support = Bundle(url: directory.appendingPathComponent("ShellMacSupport.bundle")) else {
            logger.error("ShellMacSupport.bundle is missing")
            return nil
        }
        do {
            try support.loadAndReturnError()
            guard let implementation = support.principalClass as? any MacBridge.Type else {
                logger.error("ShellMacSupport principal class does not implement ShellMacBridge")
                return nil
            }
            bundle = support
            return implementation.init()
        } catch {
            logger.error("Cannot load ShellMacSupport: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func window(for sceneID: String) -> NSObject? {
        guard !sceneID.isEmpty else { return nil }
        return bridge?.windows.first { WindowAccessor.sceneSessionId(for: $0) == sceneID }
    }
}
#endif
