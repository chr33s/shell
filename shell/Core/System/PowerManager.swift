//
//  PowerManager.swift
//  shell
//
//  Central battery/power policy: combines the user's manual refresh-rate
//  cap with automatic throttling on iOS Low Power Mode and thermal
//  pressure, and derives the frame-rate targets that the terminal display
//  link, background effects, and animated cursor modes consume.
//
//  The Adaptive refresh setting additionally follows the power source:
//  full rate on wall power, a user-chosen cap on battery.
//

import Foundation
import Observation
import UIKit
import os

#if targetEnvironment(macCatalyst) && canImport(IOKit.ps)
import IOKit.ps
#endif

extension Notification.Name {
    /// Posted when the effective power tier changes. `GhosttyApp` observes
    /// this and pushes the new frame-rate range to every live surface;
    /// other animation drivers re-read their targets from `PowerManager`.
    static let powerTierChanged = Notification.Name("dev.chr33s.shell.powerTierChanged")
}

/// Modeled on `BrightnessManager` (`@Observable` singleton, UserDefaults
/// `didSet`, NotificationCenter broadcast).
@MainActor
@Observable
final class PowerManager {
    static let shared = PowerManager()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "PowerManager")


    // MARK: - Types

    enum RefreshRateSetting: String, CaseIterable {
        case auto
        case sixty
        case thirty
        case adaptive

        var displayName: String {
            switch self {
            case .auto:
                return String(localized: "Auto", comment: "Refresh rate: device maximum")
            case .sixty:
                return String(localized: "60 Hz", comment: "Refresh rate capped at 60Hz")
            case .thirty:
                return String(localized: "30 Hz", comment: "Refresh rate capped at 30Hz")
            case .adaptive:
                return String(localized: "Adaptive", comment: "Refresh rate: follows the power source")
            }
        }
    }

    /// Refresh cap applied while running on battery, when the maximum
    /// refresh rate is set to `.adaptive`.
    enum BatteryRefreshRate: String, CaseIterable {
        case sixty
        case thirty

        /// The manual setting this is equivalent to, so the tier
        /// derivation has a single code path.
        var refreshRate: RefreshRateSetting {
            switch self {
            case .sixty: return .sixty
            case .thirty: return .thirty
            }
        }

        var displayName: String { refreshRate.displayName }
    }

    /// The effective power tier, most throttled wins.
    enum PowerTier: Equatable {
        case full
        case reduced
        case saver

        var displayName: String {
            switch self {
            case .full:
                return String(localized: "Full Performance", comment: "Power tier: no throttling")
            case .reduced:
                return String(localized: "Reduced (60 Hz)", comment: "Power tier: 60Hz cap")
            case .saver:
                return String(localized: "Battery Saver", comment: "Power tier: maximum savings")
            }
        }
    }

    // MARK: - Persisted settings

    /// Manual cap on the terminal refresh rate.
    var maxRefreshRate: RefreshRateSetting = .auto {
        didSet {
            guard maxRefreshRate != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Power.maxRefreshRate, maxRefreshRate) }
            tierMayHaveChanged()
        }
    }

    /// Cap used while on battery when `maxRefreshRate` is `.adaptive`.
    var batteryRefreshRate: BatteryRefreshRate = .sixty {
        didSet {
            guard batteryRefreshRate != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Power.batteryRefreshRate, batteryRefreshRate) }
            tierMayHaveChanged()
        }
    }

    /// When on, Low Power Mode or serious/critical thermal state drops the
    /// app to the saver tier automatically.
    var autoSaverEnabled: Bool = true {
        didSet {
            guard autoSaverEnabled != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Power.autoSaver, autoSaverEnabled) }
            tierMayHaveChanged()
        }
    }

    private static let ownedKeys: Set<String> = [
        Settings.Power.maxRefreshRate.name, Settings.Power.batteryRefreshRate.name, Settings.Power.autoSaver.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Power.maxRefreshRate.name) { maxRefreshRate = store.get(Settings.Power.maxRefreshRate) }
        if keys.contains(Settings.Power.batteryRefreshRate.name) {
            batteryRefreshRate = store.get(Settings.Power.batteryRefreshRate)
        }
        if keys.contains(Settings.Power.autoSaver.name) { autoSaverEnabled = store.get(Settings.Power.autoSaver) }
    }

    // MARK: - Observed system state

    private(set) var lowPowerModeActive: Bool
    private(set) var thermalThrottleActive: Bool

    /// True when running on wall/external power, or when the power source
    /// can't be determined (desktop Macs, Simulator) — an unknown source
    /// never throttles.
    private(set) var onExternalPower: Bool

    // MARK: - Derived tier and targets

    /// The refresh setting actually in force, after resolving `.adaptive`
    /// against the current power source.
    var effectiveRefreshRate: RefreshRateSetting {
        guard maxRefreshRate == .adaptive else { return maxRefreshRate }
        return onExternalPower ? .auto : batteryRefreshRate.refreshRate
    }

    /// Most throttled wins, so wall power returning to Auto still doesn't
    /// defeat Low Power Mode or thermal throttling. Charging is exactly
    /// when a device runs hot, so un-throttling then would be backwards.
    var tier: PowerTier {
        let refresh = effectiveRefreshRate
        if refresh == .thirty { return .saver }
        if autoSaverEnabled && (lowPowerModeActive || thermalThrottleActive) { return .saver }
        if refresh == .sixty { return .reduced }
        return .full
    }

    /// Frame-rate range for the core terminal display link, in the
    /// `ghostty_surface_set_frame_rate_range` convention: (0, 0, 0) resets
    /// to the renderer's built-in default (60/120/120).
    var coreFrameRange: (min: UInt16, max: UInt16, preferred: UInt16) {
        switch tier {
        case .full: return (0, 0, 0)
        case .reduced: return (30, 60, 60)
        case .saver: return (15, 30, 30)
        }
    }

    /// Multiplier applied to background-effect `TimelineView` minimum
    /// intervals (2.0 = half the frame rate).
    var effectIntervalScale: Double {
        tier == .saver ? 2.0 : 1.0
    }

    /// In the saver tier, animated cursor blink modes (30fps continuous on
    /// the render thread) fall back to classic blink.
    var throttleAnimatedCursor: Bool {
        tier == .saver
    }

    // MARK: - Private

    /// Last tier we broadcast, so system-state flips that don't change the
    /// effective tier (e.g. Low Power Mode toggling while manually capped
    /// at 30) don't spam notifications. Seeded from the live tier at the
    /// end of `init`.
    private var lastNotifiedTier: PowerTier = .full

    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var batteryStateObserver: NSObjectProtocol?
    private var foregroundObservers: [NSObjectProtocol] = []
    private var powerSourceDebounceTask: Task<Void, Never>?

    #if targetEnvironment(macCatalyst) && canImport(IOKit.ps)
    private var powerSourceRunLoopSource: CFRunLoopSource?
    #endif

    private init() {
        let store = SettingsStore.shared
        let refresh = store.get(Settings.Power.maxRefreshRate)
        let battery = store.get(Settings.Power.batteryRefreshRate)
        let autoSaver = store.get(Settings.Power.autoSaver)

        let info = ProcessInfo.processInfo
        let lpm = info.isLowPowerModeEnabled
        let thermal = Self.isThrottling(info.thermalState)
        let external = Self.readExternalPower()

        maxRefreshRate = refresh
        batteryRefreshRate = battery
        autoSaverEnabled = autoSaver
        lowPowerModeActive = lpm
        thermalThrottleActive = thermal
        onExternalPower = external

        // Stored-property observers don't fire during init, so seed the
        // broadcast baseline from the live tier now that all state is set.
        lastNotifiedTier = tier

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }

        // These notifications can fire on background threads; hop to the
        // main actor before touching state.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                PowerManager.shared.refreshSystemState()
            }
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                PowerManager.shared.refreshSystemState()
            }
        }
        batteryStateObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                PowerManager.shared.schedulePowerSourceRefresh()
            }
        }

        // Battery-state notifications aren't delivered while suspended, so a
        // plug/unplug in the background would otherwise leave every surface
        // pinned at a stale frame rate. Re-poll on resume. Both names are
        // observed because didBecomeActive is unreliable on Catalyst; the
        // tier dedup makes the double-fire free.
        for name in [UIApplication.willEnterForegroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                Task { @MainActor in
                    PowerManager.shared.refreshSystemState()
                }
            }
            foregroundObservers.append(observer)
        }

        startPowerSourceNotifications()
    }

    /// Coalesce bursts of battery-state changes. Plugging in walks through
    /// intermediate states, and a loose cable can oscillate; each accepted
    /// transition costs a frame-rate sweep across every surface, so absorb
    /// the burst first. Well below the threshold of noticing.
    func schedulePowerSourceRefresh() {
        powerSourceDebounceTask?.cancel()
        powerSourceDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            PowerManager.shared.refreshSystemState()
        }
    }

    /// Re-read Low Power Mode, thermal state, and the power source,
    /// broadcasting if the effective tier changed.
    func refreshSystemState() {
        let info = ProcessInfo.processInfo
        let lpm = info.isLowPowerModeEnabled
        let thermal = Self.isThrottling(info.thermalState)
        let external = Self.readExternalPower()
        guard lpm != lowPowerModeActive
            || thermal != thermalThrottleActive
            || external != onExternalPower else { return }
        lowPowerModeActive = lpm
        thermalThrottleActive = thermal
        onExternalPower = external
        tierMayHaveChanged()
    }

    private static func isThrottling(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    // MARK: - Power source

    /// True when on wall/external power. An undeterminable source counts as
    /// external so we never throttle on a guess.
    private static func readExternalPower() -> Bool {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            // Never turned back off: the shell prompt's battery variable
            device.isBatteryMonitoringEnabled = true
        }

        switch device.batteryState {
        case .charging, .full:
            return true
        case .unplugged:
            return false
        case .unknown:
            return readExternalPowerFallback()
        @unknown default:
            return true
        }
    }

    #if targetEnvironment(macCatalyst) && canImport(IOKit.ps)
    /// Macs frequently report `.unknown` through UIDevice, so ask IOKit,
    /// which also correctly reports AC on desktop Macs with no battery.
    private static func readExternalPowerFallback() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return true
        }
        return (type as String) != kIOPMBatteryPowerKey
    }
    #else
    private static func readExternalPowerFallback() -> Bool { true }
    #endif

    /// Catalyst keeps running while unfocused, and UIDevice may never report
    /// a battery-state change there, so listen to IOKit directly.
    private func startPowerSourceNotifications() {
        #if targetEnvironment(macCatalyst) && canImport(IOKit.ps)
        // A literal closure with no captures is the only form that converts
        // to a C function pointer.
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in
                PowerManager.shared.schedulePowerSourceRefresh()
            }
        }, nil)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        #endif
    }

    private func tierMayHaveChanged() {
        let newTier = tier
        guard newTier != lastNotifiedTier else { return }
        lastNotifiedTier = newTier
        let tierName = newTier.displayName
        let lpm = lowPowerModeActive
        let thermal = thermalThrottleActive
        let external = onExternalPower
        Self.logger.info("Power tier -> \(tierName) (lowPower=\(lpm) thermal=\(thermal) external=\(external))")
        NotificationCenter.default.post(name: .powerTierChanged, object: nil)
    }
}
