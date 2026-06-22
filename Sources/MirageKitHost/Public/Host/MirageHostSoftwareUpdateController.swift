//
//  MirageHostSoftwareUpdateController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update coordination contract.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Loom

#if os(macOS)

/// Software update feed selected by the host.
public enum MirageHostSoftwareUpdateChannel: String, Sendable, Codable {
    /// Stable public release feed.
    case release
    /// Nightly feed for prerelease host builds.
    case nightly
}

/// Host-side automation level for software updates.
public enum MirageHostSoftwareUpdateAutomationMode: String, Sendable, Codable {
    /// Check for update metadata only.
    case metadataOnly
    /// Download available updates without installing them.
    case autoDownload
    /// Download and install available updates when policy allows.
    case autoInstall
}

/// Current state of a host software update install workflow.
public enum MirageHostSoftwareUpdateInstallDisposition: String, Sendable, Codable {
    /// No update workflow is active.
    case idle
    /// The updater is checking for available releases.
    case checking
    /// A newer release is available.
    case updateAvailable
    /// An update archive is downloading.
    case downloading
    /// The host is applying the update.
    case installing
    /// The latest install workflow completed.
    case completed
    /// Policy or runtime conditions prevented installation.
    case blocked
    /// The latest install workflow failed.
    case failed
}

/// Reason a client-initiated host software update install was blocked.
public enum MirageHostSoftwareUpdateBlockReason: String, Sendable, Codable {
    /// Client-initiated installs are disabled.
    case clientUpdatesDisabled
    /// The host updater is already processing another request.
    case hostUpdaterBusy
    /// The available update cannot be installed unattended.
    case unattendedInstallUnsupported
    /// The host lacks permission to apply the update.
    case insufficientPermissions
    /// The update requires interactive authorization.
    case authorizationRequired
    /// The update backend is unavailable.
    case serviceUnavailable
    /// Host policy denied the request.
    case policyDenied
    /// The host could not classify the blocker.
    case unknown

    /// User-facing explanation of why the update request was blocked.
    public var displayMessage: String {
        switch self {
        case .clientUpdatesDisabled:
            "Client updates are disabled."
        case .hostUpdaterBusy:
            "Updater is busy."
        case .unattendedInstallUnsupported:
            "Unattended install is unsupported."
        case .insufficientPermissions:
            "Insufficient permissions."
        case .authorizationRequired:
            "Authorization required."
        case .serviceUnavailable:
            "Update service unavailable."
        case .policyDenied:
            "Blocked by host policy."
        case .unknown:
            "Unknown."
        }
    }
}

/// Result code returned when a client asks the host to install an update.
public enum MirageHostSoftwareUpdateInstallResultCode: String, Sendable, Codable {
    /// The install request was accepted and started.
    case started
    /// Another install request is already running.
    case alreadyInProgress
    /// The host does not have an update available.
    case noUpdateAvailable
    /// The request was denied by authorization policy.
    case denied
    /// Runtime conditions blocked the request.
    case blocked
    /// The install request failed.
    case failed
    /// Host update installation is unavailable.
    case unavailable
}

/// Format of software update release notes returned by the host.
public enum MirageHostSoftwareUpdateReleaseNotesFormat: String, Sendable, Codable {
    /// Plain text release notes.
    case plainText
    /// HTML release notes.
    case html
}

/// Snapshot of the host software update subsystem.
public struct MirageHostSoftwareUpdateStatusSnapshot: Sendable, Codable, Equatable {
    /// Whether the host updater integration is available.
    public let isSparkleAvailable: Bool
    /// Whether the host is currently checking for updates.
    public let isCheckingForUpdates: Bool
    /// Whether an update install workflow is in progress.
    public let isInstallInProgress: Bool
    /// Selected software update channel.
    public let channel: MirageHostSoftwareUpdateChannel
    /// Current update automation mode.
    public let automationMode: MirageHostSoftwareUpdateAutomationMode
    /// Current install workflow disposition.
    public let installDisposition: MirageHostSoftwareUpdateInstallDisposition
    /// Most recent blocker, if installation was blocked.
    public let lastBlockReason: MirageHostSoftwareUpdateBlockReason?
    /// Most recent install result code.
    public let lastInstallResultCode: MirageHostSoftwareUpdateInstallResultCode?
    /// Whether the active update workflow can be cancelled.
    public let canCancelUpdate: Bool
    /// Expected download size in bytes, when known.
    public let downloadExpectedBytes: UInt64?
    /// Bytes downloaded for the active update.
    public let downloadReceivedBytes: UInt64
    /// Extraction progress from `0...1`, when available.
    public let extractionProgress: Double?
    /// Short user-facing summary of the latest update error.
    public let lastErrorSummary: String?
    /// Detailed diagnostic text for the latest update error.
    public let lastErrorDetails: String?
    /// Installed host app version.
    public let currentVersion: String
    /// Available host app version, when an update is known.
    public let availableVersion: String?
    /// Display title for the available version.
    public let availableVersionTitle: String?
    /// Short release notes summary for the available update.
    public let releaseNotesSummary: String?
    /// Full release notes body for the available update.
    public let releaseNotesBody: String?
    /// Format of `releaseNotesBody`.
    public let releaseNotesFormat: MirageHostSoftwareUpdateReleaseNotesFormat?
    /// Unix timestamp milliseconds when the host last checked for updates.
    public let lastCheckedAtMs: Int64?

    /// Creates a complete host software-update status snapshot.
    public init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: MirageHostSoftwareUpdateChannel,
        automationMode: MirageHostSoftwareUpdateAutomationMode,
        installDisposition: MirageHostSoftwareUpdateInstallDisposition,
        lastBlockReason: MirageHostSoftwareUpdateBlockReason?,
        lastInstallResultCode: MirageHostSoftwareUpdateInstallResultCode?,
        canCancelUpdate: Bool,
        downloadExpectedBytes: UInt64?,
        downloadReceivedBytes: UInt64,
        extractionProgress: Double?,
        lastErrorSummary: String?,
        lastErrorDetails: String?,
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
        self.canCancelUpdate = canCancelUpdate
        self.downloadExpectedBytes = downloadExpectedBytes
        self.downloadReceivedBytes = downloadReceivedBytes
        self.extractionProgress = extractionProgress
        self.lastErrorSummary = lastErrorSummary
        self.lastErrorDetails = lastErrorDetails
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.availableVersionTitle = availableVersionTitle
        self.releaseNotesSummary = releaseNotesSummary
        self.releaseNotesBody = releaseNotesBody
        self.releaseNotesFormat = releaseNotesFormat
        self.lastCheckedAtMs = lastCheckedAtMs
    }
}

public extension MirageHostSoftwareUpdateStatusSnapshot {
    /// Extraction progress clamped to the range consumed by UI progress views.
    var normalizedExtractionProgress: Double? {
        guard let extractionProgress else {
            return nil
        }
        return min(max(extractionProgress, 0), 1)
    }

    /// Download progress clamped to the range consumed by UI progress views.
    var downloadProgressFraction: Double? {
        guard let downloadExpectedBytes, downloadExpectedBytes > 0 else {
            return nil
        }

        let fraction = Double(downloadReceivedBytes) / Double(downloadExpectedBytes)
        return min(max(fraction, 0), 1)
    }

    /// Active update progress, preferring extraction over download progress.
    var activeProgressFraction: Double? {
        normalizedExtractionProgress ?? downloadProgressFraction
    }

    /// First non-empty user-facing update error text.
    var primaryErrorText: String? {
        for candidate in [lastErrorSummary, lastErrorDetails] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

/// Result returned after a client asks the host to install a software update.
public struct MirageHostSoftwareUpdateInstallResult: Sendable, Codable, Equatable {
    /// Whether the host accepted the install request.
    public let accepted: Bool
    /// User-facing result message.
    public let message: String
    /// Machine-readable result code.
    public let code: MirageHostSoftwareUpdateInstallResultCode
    /// Block reason when the request was not accepted.
    public let blockReason: MirageHostSoftwareUpdateBlockReason?
    /// Suggested remediation for a blocked or failed request.
    public let remediationHint: String?
    /// Software update status after evaluating the request.
    public let status: MirageHostSoftwareUpdateStatusSnapshot

    /// Creates the result returned for a client-initiated install request.
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
    /// Returns the host's current software update status snapshot.
    @MainActor
    func softwareUpdateStatus(
        forceRefresh: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot

    /// Starts an immediate host software update install for an authenticated peer.
    @MainActor
    func performSoftwareUpdateInstall(
        for peer: LoomPeerIdentity
    ) async -> MirageHostSoftwareUpdateInstallResult
}

/// Host software update coordinator that accepts Mirage-owned authenticated peer identities.
public protocol MirageHostSoftwareUpdateIdentityController: MirageHostSoftwareUpdateController {
    /// Starts an immediate host software update install for an authenticated peer.
    @MainActor
    func performSoftwareUpdateInstall(
        for peer: MirageAuthenticatedPeerIdentity
    ) async -> MirageHostSoftwareUpdateInstallResult
}

#endif
