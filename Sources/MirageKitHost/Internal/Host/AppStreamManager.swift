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
/// handles deterministic window diffing and exclusive access
public actor AppStreamManager {
    let logger = Logger(subsystem: "MirageKit", category: "AppStreamManager")

    /// Active app streaming sessions keyed by bundle identifier
    var sessions: [String: MirageAppStreamSession] = [:]

    /// Reservation duration after unexpected disconnect (seconds)
    public var disconnectReservationDuration: TimeInterval = 30.0

    /// Callbacks for notifying the host service of events
    var onNewWindowDetected: (@Sendable (String, AppStreamWindowCandidate) async -> Void)?
    var onWindowClosed: (@Sendable (String, WindowID) async -> Void)?
    var onAppTerminated: (@Sendable (String) async -> Void)?
    var onAuxiliaryWindowDetected: (@Sendable (String, AppStreamWindowCandidate) async -> Void)?
    var onAuxiliaryWindowClosed: (@Sendable (String, WindowID) async -> Void)?

    /// Known auxiliary window IDs per session, used to detect appearance/disappearance.
    var knownAuxiliaryWindowIDs: [String: Set<WindowID>] = [:]

    /// Setters for callbacks (allows setting from outside the actor)
    func setOnNewWindowDetected(_ callback: @escaping @Sendable (String, AppStreamWindowCandidate) async -> Void) {
        onNewWindowDetected = callback
    }

    public func setOnWindowClosed(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        onWindowClosed = callback
    }

    public func setOnAppTerminated(_ callback: @escaping @Sendable (String) async -> Void) {
        onAppTerminated = callback
    }

    func setOnAuxiliaryWindowDetected(_ callback: @escaping @Sendable (String, AppStreamWindowCandidate) async -> Void) {
        onAuxiliaryWindowDetected = callback
    }

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

    public init() {
        applicationScanner = ApplicationScanner()
    }
}

#endif
