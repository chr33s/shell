//
//  Settings+Connections.swift
//  shell
//
//  SSH, tmux, and host-trust setting keys.
//

import Foundation

extension KeyAuthRequirement: SettingValue {}
extension KeyStorageLevel: SettingValue {}
extension TmuxAutoMode: SettingValue {}
extension TmuxMode: SettingValue {}
extension TmuxTabCloseAction: SettingValue {}
extension TmuxNewTabAction: SettingValue {}

nonisolated extension Settings {
    enum Connections {
        static let forceIPv4 = SettingKey(
            "sshForceIPv4Enabled", default: false, group: .connections, configKey: "ssh-force-ipv4-enabled",
            title: String(localized: "Force IPv4", comment: "Setting title"))
        static let healthMonitoring = SettingKey(
            "sshHealthMonitoringEnabled", default: true, group: .connections, configKey: "ssh-health-monitoring-enabled",
            title: String(localized: "Connection Health Monitoring", comment: "Setting title"))
        static let healthProbeInterval = SettingKey(
            "sshHealthProbeInterval", default: 15, group: .connections, configKey: "ssh-health-probe-interval",
            title: String(localized: "Probe Interval", comment: "Setting title"))
        static let backgroundKeepalive = SettingKey(
            "backgroundSessionKeepaliveEnabled", default: true, group: .connections, configKey: "background-session-keepalive-enabled",
            title: String(localized: "Keep SSH Alive in Background", comment: "Setting title"))
        static let autoReconnectEnabled = SettingKey(
            "autoReconnectEnabled", default: true, group: .connections, configKey: "auto-reconnect-enabled",
            title: String(localized: "Auto Reconnect", comment: "Setting title"))
        static let autoReconnectMaxAttempts = SettingKey(
            "autoReconnectMaxAttempts", default: 5, group: .connections, configKey: "auto-reconnect-max-attempts",
            title: String(localized: "Reconnect Attempts", comment: "Setting title"))
        static let passwordDefaultAuthRequirement = SettingKey(
            "sshPasswordDefaultAuthRequirement", default: KeyAuthRequirement.none, group: .connections,
            configKey: "ssh-password-default-auth-requirement",
            title: String(localized: "Saved Password Authentication", comment: "Setting title"))
        static let passwordDefaultStorageLevel = SettingKey(
            "sshPasswordDefaultStorageLevel", default: KeyStorageLevel.backupOnly, group: .connections,
            configKey: "ssh-password-default-storage-level",
            title: String(localized: "Saved Password Storage", comment: "Setting title"))
        static let passwordLastUsedDates = SettingKey<Data?>(
            "sshPasswordLastUsedDates", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Password Last Used", comment: "Setting title"))
        static let defaultKeyIDs = SettingKey<Data?>(
            "defaultSSHKeyIDs", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Default SSH Identities", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            forceIPv4.erased, healthMonitoring.erased, healthProbeInterval.erased,
            backgroundKeepalive.erased, autoReconnectEnabled.erased,
            autoReconnectMaxAttempts.erased, passwordDefaultAuthRequirement.erased,
            passwordDefaultStorageLevel.erased,
            passwordLastUsedDates.erased, defaultKeyIDs.erased,
        ]
    }

    /// tmux settings — the fork's only multiplexer (spec section 12).
    enum Tmux {
        static let defaultMode = SettingKey(
            "tmuxDefaultMode", default: TmuxMode.off, group: .tmux, configKey: "tmux-default-mode",
            title: String(localized: "Default Mode", comment: "Setting title"))
        static let defaultSessionName = SettingKey(
            "tmuxSessionName", default: "", group: .tmux, configKey: "tmux-session-name",
            title: String(localized: "Default Session Name", comment: "Setting title"))
        static let newTabAction = SettingKey(
            "tmuxNewTabAction", default: TmuxNewTabAction.localShell, group: .tmux, configKey: "tmux-new-tab-action",
            title: String(localized: "New Tab Action", comment: "Setting title"))
        static let tabCloseAction = SettingKey(
            "tmuxTabCloseAction", default: TmuxTabCloseAction.closeWindow, group: .tmux, configKey: "tmux-close-window-behavior",
            title: String(localized: "Close-Window Behavior", comment: "Setting title"))
        static let lastSessionByConnection = AnySettingDefinition.opaque(
            "tmuxLastSessionByConnection", group: .tmux,
            title: String(localized: "tmux Last Session", comment: "Setting title"))
        /// Mode used when attaching to a tmux server discovered on the remote
        /// host, rather than one this app started.
        static let discoveryAttachMode = SettingKey(
            "tmuxDiscoveryAttachMode", default: TmuxAutoMode.regular, group: .tmux,
            configKey: "tmux-discovery-attach-mode",
            title: String(localized: "Discovered Session Mode", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            defaultMode.erased, defaultSessionName.erased, newTabAction.erased, tabCloseAction.erased,
            discoveryAttachMode.erased, lastSessionByConnection,
        ]
    }
}
