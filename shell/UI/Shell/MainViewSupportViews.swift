//
//  MainViewSupportViews.swift
//  shell
//
//  Standalone helper views and modifiers used by MainView's body and
//  modifier pipeline, extracted for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// ConnectionSheetModifier has been replaced by ConnectionSidebarModifier
// (see ConnectionSidebarModifier.swift)

// MARK: - Health Popover

// MARK: - Current Window Title Accessor

/// Wraps `WindowAccessor` so the selected tab's title is read inside this
/// child view's body, not at MainView body construction time. Without this
/// indirection, MainView reads `terminals[selectedTabIndex].title` itself,
/// which registers per-tab title Observation on `MainView.body` — every
/// reconnect-driven OSC 0/2 title update then invalidates the entire
/// MainView graph and contributes to the 0x8BADF00D scene-update budget
/// pressure documented in the crash IPS files.
struct CurrentWindowTitleAccessor: View {
    let tabsModel: TabsModel

    var body: some View {
        let title: String = {
            let selectedTab = tabsModel.selectedTab ?? tabsModel.tabs.first
            guard let selectedTab else { return "Terminal" }
            return selectedTab.title
        }()
        WindowAccessor(windowTitle: title)
    }
}

// MARK: - Tab Indicator Overlay

/// Overlay shown briefly when switching tabs with the tab bar hidden.
/// Displays the current tab title, optional keyboard shortcut, and position indicator dots.
///
/// Takes the `TabModel` reference rather than a `String tabTitle` so the
/// `tab.title` Observation read happens inside this view's body. With the
/// previous `String`-parameter shape, MainView had to read the title at
/// construction time, which registered per-tab title observation on
/// `MainView.body` and made every reconnect-driven OSC 0/2 title update
/// invalidate the entire MainView graph.
struct TabIndicatorOverlay: View {
    let tab: TabModel?
    let allTabs: [TabModel]
    let currentIndex: Int
    let totalCount: Int
    let keyboardShortcut: String?
    let tmuxBadgePalette: TmuxTabBadgePalette

    var body: some View {
        VStack(spacing: 12) {
            // Tab title with optional keyboard shortcut
            if let tab {
                TabTitleLine(
                    tab: tab,
                    allTabs: allTabs,
                    tmuxBadgePalette: tmuxBadgePalette,
                    keyboardShortcut: keyboardShortcut
                )
            } else {
                Text("Terminal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            // Position indicator dots
            if totalCount > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalCount, id: \.self) { index in
                        Circle()
                            .fill(index == currentIndex ? Color.white : Color.white.opacity(0.4))
                            .frame(width: index == currentIndex ? 8 : 6, height: index == currentIndex ? 8 : 6)
                            .animation(.easeInOut(duration: 0.15), value: currentIndex)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

// MARK: - AI Agent Sidebar Container

struct ContainerCornerModifier: ViewModifier {
    func body(content: Content) -> some View {
#if os(visionOS)
        // containerCornerOffset is not available on visionOS
        content
#else
        if #available(iOS 26.0, *) {
            content.containerCornerOffset(.leading, sizeToFit: true)
        } else {
            content
        }
#endif
    }
}

// MARK: - Titlebar Tabs Modifier

struct TitlebarTabsModifier: ViewModifier {
    let isEnabled: Bool
    let fullScreenEnabled: Bool

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        if isEnabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
#elseif !os(visionOS)
        if fullScreenEnabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
#else
        content
#endif
    }
}
