//
//  AppStreamManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageKit
#if os(macOS)
import Foundation
import OSLog

/// Manages app-centric streaming sessions, window inventory, monitoring, and installed app scans.
actor AppStreamManager {
    let logger = Logger(subsystem: "MirageKit", category: "AppStreamManager")

    /// Active app streaming sessions keyed by bundle identifier
    var sessions: [String: MirageAppStreamSession] = [:]

    /// Callbacks for notifying the host service of events
    var onNewWindowDetected: (@Sendable (String, AppStreamWindowCandidate) async -> Void)?
    var onWindowClosed: (@Sendable (String, WindowID) async -> Void)?
    var onAppTerminated: (@Sendable (String) async -> Void)?
    var onAuxiliaryWindowDetected: (@Sendable (String, AppStreamWindowCandidate) async -> Void)?
    var onAuxiliaryWindowClosed: (@Sendable (String, WindowID) async -> Void)?

    /// Known auxiliary window IDs per session, used to detect appearance/disappearance.
    var knownAuxiliaryWindowIDs: [String: Set<WindowID>] = [:]

    /// Sets the callback invoked when a new primary window appears for a session.
    func setOnNewWindowDetected(_ callback: @escaping @Sendable (String, AppStreamWindowCandidate) async -> Void) {
        onNewWindowDetected = callback
    }

    /// Sets the callback invoked when a visible session window closes.
    func setOnWindowClosed(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        onWindowClosed = callback
    }

    /// Sets the callback invoked when a streamed app terminates.
    func setOnAppTerminated(_ callback: @escaping @Sendable (String) async -> Void) {
        onAppTerminated = callback
    }

    /// Sets the callback invoked when an auxiliary window appears for a session.
    func setOnAuxiliaryWindowDetected(_ callback: @escaping @Sendable (String, AppStreamWindowCandidate) async -> Void) {
        onAuxiliaryWindowDetected = callback
    }

    /// Sets the callback invoked when an auxiliary window closes.
    func setOnAuxiliaryWindowClosed(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        onAuxiliaryWindowClosed = callback
    }

    /// Application scanner for getting installed apps
    let applicationScanner: ApplicationScanner
    var cachedAppsWithIcons: [MirageInstalledApp] = []
    var cachedAppsWithoutIcons: [MirageInstalledApp] = []
    var lastAppsScanWithIconsAt: Date?
    var lastAppsScanWithoutIconsAt: Date?
    var appScanTaskWithIcons: Task<[MirageInstalledApp], Never>?
    var appScanTaskWithoutIcons: Task<[MirageInstalledApp], Never>?
    let appScanWithIconsTTL: TimeInterval = 120
    let appScanWithoutIconsTTL: TimeInterval = 30

    /// Timer for periodic window monitoring
    var monitoringTask: Task<Void, Never>?
    var isMonitoring = false

    /// Startup retry bookkeeping keyed by session bundle ID and window ID.
    var startupFailureStateByBundleID: [String: [WindowID: AppStreamWindowStartupFailureState]] = [:]

    /// Creates an app stream manager with a fresh application scanner.
    init() {
        applicationScanner = ApplicationScanner()
    }
}

#endif
