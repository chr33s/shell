//
//  MainViewModifiers.swift
//  shell
//
//  Notification and event handlers extracted from MainView body.
//  Helps reduce type-checking complexity.
//

import SwiftUI

// MARK: - Notification Handlers ViewModifier

/// ViewModifier that applies all notification handlers for MainView.
/// Extracted to reduce body complexity for compiler type-checking.
struct NotificationHandlersModifier: ViewModifier {
    // Publishers are stored once per program so SwiftUI sees stable
    // SubscriptionView identity across body evaluations. Constructing them
    // inline causes tear-down + resubscribe on every render, which compounds
    // during scene-update transactions (foreground resume) and contributes to
    // 0x8BADF00D watchdog kills.
    private static let toggleTabBarPublisher = NotificationCenter.default.publisher(for: .toggleTabBar)
    private static let toggleGroupModePublisher = NotificationCenter.default.publisher(for: .toggleGroupMode)
    private static let terminalRestorationStateChangedPublisher = NotificationCenter.default.publisher(for: .terminalRestorationStateChanged)
    private static let terminalRecoveryStatusChangedPublisher = NotificationCenter.default.publisher(for: .terminalRecoveryStatusChanged)
    #if targetEnvironment(macCatalyst)
    private static let toggleTransparencyPublisher = NotificationCenter.default.publisher(for: .toggleTransparency)
    private static let toggleTitleBarPublisher = NotificationCenter.default.publisher(for: .toggleTitleBar)
    #endif
    private static let toggleFullScreenPublisher = NotificationCenter.default.publisher(for: .toggleFullScreen)

    @Binding var tabBarHidden: Bool
    @Binding var restorationVersion: Int
    let windowId: String
    let tabsModel: TabsModel
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @Setting(Settings.Window.fullScreenMode) private var fullScreenModeEnabled
    #endif
    #if targetEnvironment(macCatalyst)
    @Setting(Settings.Window.hideTitleBar) private var hideWindowTitleBar
    #endif
    var shouldHandleNotification: (Notification) -> Bool

    func body(content: Content) -> some View {
        content
            .onReceive(Self.toggleTabBarPublisher) { notification in
                guard shouldHandleNotification(notification) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    tabBarHidden.toggle()
                }
                // Post layout invalidation after animation completes to ensure terminals resize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
                }
            }
            .onReceive(Self.toggleGroupModePublisher) { notification in
                guard shouldHandleNotification(notification) else { return }
                // Mirror the sidebar grid button's animated toggle of grouped mode.
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    tabsModel.isGroupedModeEnabled.toggle()
                }
            }
            .onReceive(Self.terminalRestorationStateChangedPublisher) { _ in
                // Force SwiftUI to re-evaluate reconnection overlay visibility
                restorationVersion += 1
            }
            .onReceive(Self.terminalRecoveryStatusChangedPublisher) { _ in
                // Same reason: the recovery strip reads a class property that
                // `@State` does not observe.
                restorationVersion += 1
            }
            #if targetEnvironment(macCatalyst)
            .onReceive(Self.toggleTransparencyPublisher) { notification in
                guard shouldHandleNotification(notification) else { return }
                TransparencyManager.shared.toggleTransparency()
            }
            .onReceive(Self.toggleTitleBarPublisher) { notification in
                guard shouldHandleNotification(notification) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    hideWindowTitleBar.toggle()
                }
                // Post layout invalidation after animation completes to ensure terminals resize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
                }
            }
            #endif
            .onReceive(Self.toggleFullScreenPublisher) { notification in
                guard shouldHandleNotification(notification) else { return }
                #if targetEnvironment(macCatalyst)
                if let sceneID = TerminalWindowRegistry.sceneSessionId(for: windowId),
                   let window = MacSupport.window(for: sceneID) {
                    MacSupport.bridge?.toggleFullScreen(window)
                }
                // Native macOS fullscreen animation takes ~0.7s
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
                }
                #elseif !os(visionOS)
                fullScreenModeEnabled.toggle()
                // Fallback safety nets — primary fix is event-driven via
                // WindowSceneReportingView.safeAreaInsetsDidChange().
                // Redundant notifications are harmless (sizeDidChange checks cached dimensions).
                for delay in [0.5, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
                    }
                }
                #endif
            }
    }
}
