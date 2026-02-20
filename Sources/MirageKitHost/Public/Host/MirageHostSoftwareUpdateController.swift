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

public enum MirageHostSoftwareUpdateAutomationMode: String, Sendable, Codable {
    case metadataOnly
    case autoDownload
    case autoInstall
}

public enum MirageHostSoftwareUpdateInstallDisposition: String, Sendable, Codable {
    case idle
    case checking
    case updateAvailable
    case downloading
    case installing
    case completed
    case blocked
    case failed
}

public enum MirageHostSoftwareUpdateBlockReason: String, Sendable, Codable {
    case clientUpdatesDisabled
    case hostUpdaterBusy
    case unattendedInstallUnsupported
    case insufficientPermissions
    case authorizationRequired
    case serviceUnavailable
    case policyDenied
    case unknown
}

public enum MirageHostSoftwareUpdateInstallResultCode: String, Sendable, Codable {
    case started
    case alreadyInProgress
    case noUpdateAvailable
    case denied
    case blocked
    case failed
    case unavailable
}

public enum MirageHostSoftwareUpdateReleaseNotesFormat: String, Sendable, Codable {
    case plainText
    case html
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
    public let automationMode: MirageHostSoftwareUpdateAutomationMode
    public let installDisposition: MirageHostSoftwareUpdateInstallDisposition
    public let lastBlockReason: MirageHostSoftwareUpdateBlockReason?
    public let lastInstallResultCode: MirageHostSoftwareUpdateInstallResultCode?
    public let currentVersion: String
    public let availableVersion: String?
    public let availableVersionTitle: String?
    public let releaseNotesSummary: String?
    public let releaseNotesBody: String?
    public let releaseNotesFormat: MirageHostSoftwareUpdateReleaseNotesFormat?
    /// Unix timestamp milliseconds when the host last checked for updates.
    public let lastCheckedAtMs: Int64?

    public init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: MirageHostSoftwareUpdateChannel,
        automationMode: MirageHostSoftwareUpdateAutomationMode,
        installDisposition: MirageHostSoftwareUpdateInstallDisposition,
        lastBlockReason: MirageHostSoftwareUpdateBlockReason?,
        lastInstallResultCode: MirageHostSoftwareUpdateInstallResultCode?,
        currentVersion: String,
        availableVersion: String?,
        availableVersionTitle: String?,
        releaseNotesSummary: String?,
        releaseNotesBody: String?,
        releaseNotesFormat: MirageHostSoftwareUpdateReleaseNotesFormat?,
        lastCheckedAtMs: Int64?
    ) {
        self.isSparkleAvailable = isSparkleAvailable
        self.isCheckingForUpdates = isCheckingForUpdates
        self.isInstallInProgress = isInstallInProgress
        self.channel = channel
        self.automationMode = automationMode
        self.installDisposition = installDisposition
        self.lastBlockReason = lastBlockReason
        self.lastInstallResultCode = lastInstallResultCode
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.availableVersionTitle = availableVersionTitle
        self.releaseNotesSummary = releaseNotesSummary
        self.releaseNotesBody = releaseNotesBody
        self.releaseNotesFormat = releaseNotesFormat
        self.lastCheckedAtMs = lastCheckedAtMs
    }
}

public struct MirageHostSoftwareUpdateInstallResult: Sendable, Codable, Equatable {
    public let accepted: Bool
    public let message: String
    public let code: MirageHostSoftwareUpdateInstallResultCode
    public let blockReason: MirageHostSoftwareUpdateBlockReason?
    public let remediationHint: String?
    public let status: MirageHostSoftwareUpdateStatusSnapshot

    public init(
        accepted: Bool,
        message: String,
        code: MirageHostSoftwareUpdateInstallResultCode,
        blockReason: MirageHostSoftwareUpdateBlockReason?,
        remediationHint: String?,
        status: MirageHostSoftwareUpdateStatusSnapshot
    ) {
        self.accepted = accepted
        self.message = message
        self.code = code
        self.blockReason = blockReason
        self.remediationHint = remediationHint
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
