import Foundation

/// The only ABI shared by the Catalyst executable and the macOS support bundle.
/// AppKit objects remain opaque on the Catalyst side. All calls run on the main thread.
@objc(ShellMacBridge)
public protocol MacBridge: NSObjectProtocol {
    init()
    func createShell(executable: String, arguments: [String], environment: [String: String],
                     directory: String, rows: UInt16, columns: UInt16) throws -> any MacShellProcess
    func installTerminalEvents(
        scroll: @escaping (NSObject, CGPoint, Double, Double, Bool, Int) -> Bool,
        hover: @escaping (NSObject?, CGPoint) -> Void,
        menu: @escaping (NSObject, CGPoint) -> [any MacMenuEntry]?)
    /// Installs the Dock menu. `provider` is invoked on the main thread each time
    /// the Dock asks, so the entries reflect the app's state at click time.
    func installDockMenu(_ provider: @escaping () -> [any MacMenuEntry]) -> Bool
    func inputSources() -> [[String: String]]
    func currentInputSourceID() -> String?
    func currentInputSourceLanguages() -> [String]
    func selectInputSource(_ id: String) -> Bool
    func translateKey(_ code: UInt16, shift: Bool) -> String?
    func showAbout()
    func closeKeyWindow()
    func stopShells()
    var windows: [NSObject] { get }
    func isKeyWindow(_ window: NSObject) -> Bool
    func isVisible(_ window: NSObject) -> Bool
    func isOpaque(_ window: NSObject) -> Bool
    func frame(of window: NSObject) -> CGRect
    func setTitle(_ title: String, for window: NSObject)
    func beginWindowDrag(_ window: NSObject) -> Bool
    func toggleFullScreen(_ window: NSObject)
    /// Unhides the app, deminiaturizes `window` if needed, and orders it front.
    /// `requestSceneSessionActivation` alone can leave a Catalyst window hidden
    /// or in the Dock, so external events finish the job here.
    func activate(_ window: NSObject)
    func setAlpha(_ alpha: CGFloat, for window: NSObject)
    func configureBackground(_ transparent: Bool, for window: NSObject)
    func refresh(_ window: NSObject)
    /// True for the borderless glass backdrop windows this bundle owns, so the
    /// caller's NSApp.windows sweep skips them.
    func isMaterialBackdrop(_ window: NSObject) -> Bool
    /// Attaches (or updates) the liquid-glass backdrop behind `window`. A window
    /// that is not yet on screen, or still opaque, is left for the caller's next
    /// pass rather than given a backdrop that cannot render.
    func applyGlassBackdrop(_ window: NSObject, clear: Bool)
    func removeGlassBackdrop(_ window: NSObject)
    func setVisualEffectBlur(_ enabled: Bool, for window: NSObject)
    /// 0 = system, 1 = light, 2 = dark.
    func setApplicationAppearance(_ mode: Int)
    func titlebarLeadingInset(_ window: NSObject) -> CGFloat
    func configureTitlebar(_ window: NSObject, hidden: Bool, separatorHidden: Bool,
                          tabsInTitlebar: Bool, tabBarHidden: Bool, tabCount: Int)
}

/// Owns the child process; callers own the descriptor returned by duplicateMaster().
@objc(ShellMacShellProcess)
public protocol MacShellProcess: NSObjectProtocol {
    var processID: Int32 { get }
    var exitStatus: Int32 { get }
    func duplicateMaster() -> Int32
    func terminate(signal: Int32)
}

@objc(ShellMacMenuEntry)
public protocol MacMenuEntry: NSObjectProtocol {
    var title: String { get }
    var enabled: Bool { get }
    var state: Int { get }
    var isSeparator: Bool { get }
    var children: [any MacMenuEntry] { get }
    func invoke()
}
