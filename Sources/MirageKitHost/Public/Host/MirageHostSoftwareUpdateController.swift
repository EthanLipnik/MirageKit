//
//  MirageHostSoftwareUpdateController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update coordination contract.
//

import Foundation
import MirageKit

#if os(macOS)

public enum MirageHostSoftwareUpdateChannel: String, Sendable, Codable {
    case release
    case nightly
}

public enum MirageHostSoftwareUpdateInstallTrigger: String, Sendable, Codable {
    case protocolMismatch
    case manual
}

public struct MirageHostSoftwareUpdateStatusSnapshot: Sendable, Codable, Equatable {
    public let isSparkleAvailable: Bool
    public let isCheckingForUpdates: Bool
    public let isInstallInProgress: Bool
    public let channel: MirageHostSoftwareUpdateChannel
    public let currentVersion: String
    public let availableVersion: String?
    public let availableVersionTitle: String?
    /// Unix timestamp milliseconds when the host last checked for updates.
    public let lastCheckedAtMs: Int64?

    public init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: MirageHostSoftwareUpdateChannel,
        currentVersion: String,
        availableVersion: String?,
        availableVersionTitle: String?,
        lastCheckedAtMs: Int64?
    ) {
        self.isSparkleAvailable = isSparkleAvailable
        self.isCheckingForUpdates = isCheckingForUpdates
        self.isInstallInProgress = isInstallInProgress
        self.channel = channel
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.availableVersionTitle = availableVersionTitle
        self.lastCheckedAtMs = lastCheckedAtMs
    }
}

public struct MirageHostSoftwareUpdateInstallResult: Sendable, Codable, Equatable {
    public let accepted: Bool
    public let message: String
    public let status: MirageHostSoftwareUpdateStatusSnapshot

    public init(
        accepted: Bool,
        message: String,
        status: MirageHostSoftwareUpdateStatusSnapshot
    ) {
        self.accepted = accepted
        self.message = message
        self.status = status
    }
}

/// Host software update coordinator used by `MirageHostService` for client-initiated update workflows.
public protocol MirageHostSoftwareUpdateController: AnyObject, Sendable {
    /// Returns a software update status snapshot for the requesting peer.
    @MainActor
    func hostService(
        _ service: MirageHostService,
        softwareUpdateStatusFor peer: MiragePeerIdentity,
        forceRefresh: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot

    /// Returns whether the requesting peer is authorized to request software update installation.
    @MainActor
    func hostService(
        _ service: MirageHostService,
        shouldAuthorizeSoftwareUpdateRequestFrom peer: MiragePeerIdentity,
        trigger: MirageHostSoftwareUpdateInstallTrigger
    ) async -> Bool

    /// Executes an immediate host software update install for the requesting peer.
    @MainActor
    func hostService(
        _ service: MirageHostService,
        performSoftwareUpdateInstallFor peer: MiragePeerIdentity,
        trigger: MirageHostSoftwareUpdateInstallTrigger
    ) async -> MirageHostSoftwareUpdateInstallResult
}

#endif

