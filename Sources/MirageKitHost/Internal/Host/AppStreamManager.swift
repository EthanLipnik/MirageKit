//
//  AppStreamManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import OSLog
import ScreenCaptureKit

/// Manages app-centric streaming sessions on the host
/// Tracks which apps are being streamed to which clients,
/// handles window monitoring, cooldowns, and exclusive access
public actor AppStreamManager {
    let logger = Logger(subsystem: "MirageKit", category: "AppStreamManager")

    /// Active app streaming sessions keyed by bundle identifier
    var sessions: [String: MirageAppStreamSession] = [:]

    /// Cooldown duration when host closes a window (seconds)
    public var windowCooldownDuration: TimeInterval = 10.0

    /// Reservation duration after unexpected disconnect (seconds)
    public var disconnectReservationDuration: TimeInterval = 30.0

    /// Callbacks for notifying the host service of events
    var onNewWindowDetected: (@Sendable (String, SCWindow) async -> Void)?
    var onWindowClosed: (@Sendable (String, WindowID) async -> Void)?
    var onAppTerminated: (@Sendable (String) async -> Void)?
    var onCooldownExpired: (@Sendable (String, WindowID) async -> Void)?

    /// Setters for callbacks (allows setting from outside the actor)
    public func setOnNewWindowDetected(_ callback: @escaping @Sendable (String, SCWindow) async -> Void) {
        onNewWindowDetected = callback
    }

    public func setOnWindowClosed(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        onWindowClosed = callback
    }

    public func setOnAppTerminated(_ callback: @escaping @Sendable (String) async -> Void) {
        onAppTerminated = callback
    }

    public func setOnCooldownExpired(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        onCooldownExpired = callback
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

    public init() {
        applicationScanner = ApplicationScanner()
    }
}

#endif
