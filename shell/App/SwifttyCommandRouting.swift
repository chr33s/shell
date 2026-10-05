//
//  SwifttyCommandRouting.swift
//  shell
//
//  Shared keys for command routing notifications
//

import Foundation

enum SwifttyCommandRouting {
    static let windowSceneSessionIDKey = "windowSceneSessionID"
    static let paneCommandNotification = Notification.Name("dev.chr33s.shell.menuPaneCommand")
    static let paneCommandKey = "paneCommand"

    enum PaneCommand: Sendable {
        case clearScreen
        case scrollPageUp
        case scrollPageDown
        case scrollToTop
        case scrollToBottom
        case previousPrompt
        case nextPrompt
        case toggleCompose
        case toggleMouseCapture
        case cycleInputSource
    }
}
