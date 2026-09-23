//
//  GhosttyCommandRouting.swift
//  shell
//
//  Shared keys for command routing notifications
//

import Foundation

enum GhosttyCommandRouting {
    static let windowSceneSessionIDKey = "windowSceneSessionID"
    static let paneCommandNotification = Notification.Name("dev.chr33s.shell.menuPaneCommand")
    static let paneCommandKey = "paneCommand"

    enum PaneCommand: Sendable {
        case clearScreen
        case scrollPageUp
        case scrollPageDown
        case scrollToTop
        case scrollToBottom
        case toggleCompose
        case toggleMouseCapture
        case cycleInputSource
    }
}
