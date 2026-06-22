//
//  MirageSoftwareUpdateMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Host software update feed selected by the host.
package enum HostSoftwareUpdateChannel: String, Codable {
    /// Stable public release feed.
    case release

    /// Nightly feed for prerelease host builds.
    case nightly
}

/// Host updater automation policy exposed to connected clients.
package enum HostSoftwareUpdateAutomationMode: String, Codable {
    /// Check update metadata without downloading.
    case metadataOnly

    /// Download available updates without installing them.
    case autoDownload

    /// Download and install available updates when policy allows.
    case autoInstall
}

/// Current host software-update workflow state.
package enum HostSoftwareUpdateInstallDisposition: String, Codable {
    /// No update workflow is active.
    case idle

    /// The host is checking for available releases.
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

/// Reason a client-initiated host update install cannot proceed.
package enum HostSoftwareUpdateBlockReason: String, Codable {
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
}

/// Result code returned when a client asks the host to install an update.
package enum HostSoftwareUpdateInstallResultCode: String, Codable {
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

/// Markup format for host-provided software update release notes.
package enum HostSoftwareUpdateReleaseNotesFormat: String, Codable {
    /// Plain text release notes.
    case plainText

    /// HTML release notes.
    case html
}

/// Request host software update status from the connected host (Client -> Host).
package struct HostSoftwareUpdateStatusRequestMessage: Codable {
    /// Forces the host to refresh update availability before responding.
    package let forceRefresh: Bool

    package init(forceRefresh: Bool) {
        self.forceRefresh = forceRefresh
    }
}

/// Host software update status snapshot (Host -> Client).
package struct HostSoftwareUpdateStatusMessage: Codable {
    /// Whether the host updater integration is available.
    package let isSparkleAvailable: Bool

    /// Whether the host is currently checking for updates.
    package let isCheckingForUpdates: Bool

    /// Whether an update install workflow is in progress.
    package let isInstallInProgress: Bool

    /// Selected software update channel.
    package let channel: HostSoftwareUpdateChannel

    /// Current update automation mode.
    package let automationMode: HostSoftwareUpdateAutomationMode

    /// Current install workflow disposition.
    package let installDisposition: HostSoftwareUpdateInstallDisposition

    /// Most recent blocker, if installation was blocked.
    package let lastBlockReason: HostSoftwareUpdateBlockReason?

    /// Most recent install result code.
    package let lastInstallResultCode: HostSoftwareUpdateInstallResultCode?

    /// Whether the active update workflow can be cancelled.
    package let canCancelUpdate: Bool

    /// Expected download size in bytes, when known.
    package let downloadExpectedBytes: UInt64?

    /// Bytes downloaded for the active update.
    package let downloadReceivedBytes: UInt64

    /// Extraction progress from `0...1`, when available.
    package let extractionProgress: Double?

    /// Short user-facing summary of the latest update error.
    package let lastErrorSummary: String?

    /// Detailed diagnostic text for the latest update error.
    package let lastErrorDetails: String?

    /// Installed host app version.
    package let currentVersion: String

    /// Available host app version, when an update is known.
    package let availableVersion: String?

    /// Display title for the available version.
    package let availableVersionTitle: String?

    /// Short release notes summary for the available update.
    package let releaseNotesSummary: String?

    /// Full release notes body for the available update.
    package let releaseNotesBody: String?

    /// Format of `releaseNotesBody`.
    package let releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?

    /// Unix timestamp milliseconds when the host last checked for updates.
    package let lastCheckedAtMs: Int64?

    /// Creates a complete host software-update status payload.
    package init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: HostSoftwareUpdateChannel,
        automationMode: HostSoftwareUpdateAutomationMode,
        installDisposition: HostSoftwareUpdateInstallDisposition,
        lastBlockReason: HostSoftwareUpdateBlockReason?,
        lastInstallResultCode: HostSoftwareUpdateInstallResultCode?,
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
        releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?,
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

/// Result of a host software update install request (Host -> Client).
package struct HostSoftwareUpdateInstallResultMessage: Codable {
    /// User-facing result message.
    package let message: String

    /// Machine-readable result code.
    package let resultCode: HostSoftwareUpdateInstallResultCode

    /// Block reason when the request was not accepted.
    package let blockReason: HostSoftwareUpdateBlockReason?

    /// Suggested remediation for a blocked or failed request.
    package let remediationHint: String?

    /// Software update status after evaluating the request.
    package let status: HostSoftwareUpdateStatusMessage

    /// Creates the result returned for a client-initiated install request.
    package init(
        message: String,
        resultCode: HostSoftwareUpdateInstallResultCode,
        blockReason: HostSoftwareUpdateBlockReason?,
        remediationHint: String?,
        status: HostSoftwareUpdateStatusMessage
    ) {
        self.message = message
        self.resultCode = resultCode
        self.blockReason = blockReason
        self.remediationHint = remediationHint
        self.status = status
    }
}
