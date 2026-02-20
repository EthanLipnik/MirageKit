//
//  MessageTypes+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update control message type definitions.
//

import Foundation

package enum HostSoftwareUpdateChannel: String, Codable, Sendable {
    case release
    case nightly
}

package enum HostSoftwareUpdateAutomationMode: String, Codable, Sendable {
    case metadataOnly
    case autoDownload
    case autoInstall
}

package enum HostSoftwareUpdateInstallDisposition: String, Codable, Sendable {
    case idle
    case checking
    case updateAvailable
    case downloading
    case installing
    case completed
    case blocked
    case failed
}

package enum HostSoftwareUpdateBlockReason: String, Codable, Sendable {
    case clientUpdatesDisabled
    case hostUpdaterBusy
    case unattendedInstallUnsupported
    case insufficientPermissions
    case authorizationRequired
    case serviceUnavailable
    case policyDenied
    case unknown
}

package enum HostSoftwareUpdateInstallResultCode: String, Codable, Sendable {
    case started
    case alreadyInProgress
    case noUpdateAvailable
    case denied
    case blocked
    case failed
    case unavailable
}

package enum HostSoftwareUpdateReleaseNotesFormat: String, Codable, Sendable {
    case plainText
    case html
}

/// Request host software update status from the connected host (Client -> Host).
package struct HostSoftwareUpdateStatusRequestMessage: Codable, Sendable {
    /// Forces the host to refresh update availability before responding.
    package let forceRefresh: Bool

    package init(forceRefresh: Bool) {
        self.forceRefresh = forceRefresh
    }
}

/// Host software update status snapshot (Host -> Client).
package struct HostSoftwareUpdateStatusMessage: Codable, Sendable {
    package let isSparkleAvailable: Bool
    package let isCheckingForUpdates: Bool
    package let isInstallInProgress: Bool
    package let channel: HostSoftwareUpdateChannel
    package let automationMode: HostSoftwareUpdateAutomationMode?
    package let installDisposition: HostSoftwareUpdateInstallDisposition?
    package let lastBlockReason: HostSoftwareUpdateBlockReason?
    package let lastInstallResultCode: HostSoftwareUpdateInstallResultCode?
    package let currentVersion: String
    package let availableVersion: String?
    package let availableVersionTitle: String?
    package let releaseNotesSummary: String?
    package let releaseNotesBody: String?
    package let releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?
    /// Unix timestamp milliseconds when the host last checked for updates.
    package let lastCheckedAtMs: Int64?

    package init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: HostSoftwareUpdateChannel,
        automationMode: HostSoftwareUpdateAutomationMode?,
        installDisposition: HostSoftwareUpdateInstallDisposition?,
        lastBlockReason: HostSoftwareUpdateBlockReason?,
        lastInstallResultCode: HostSoftwareUpdateInstallResultCode?,
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
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.availableVersionTitle = availableVersionTitle
        self.releaseNotesSummary = releaseNotesSummary
        self.releaseNotesBody = releaseNotesBody
        self.releaseNotesFormat = releaseNotesFormat
        self.lastCheckedAtMs = lastCheckedAtMs
    }
}

/// Request host software update install action (Client -> Host).
package struct HostSoftwareUpdateInstallRequestMessage: Codable, Sendable {
    package enum Trigger: String, Codable, Sendable {
        case protocolMismatch
        case manual
    }

    package let trigger: Trigger

    package init(trigger: Trigger) {
        self.trigger = trigger
    }
}

/// Result of a host software update install request (Host -> Client).
package struct HostSoftwareUpdateInstallResultMessage: Codable, Sendable {
    package let accepted: Bool
    package let message: String
    package let resultCode: HostSoftwareUpdateInstallResultCode?
    package let blockReason: HostSoftwareUpdateBlockReason?
    package let remediationHint: String?
    package let status: HostSoftwareUpdateStatusMessage?

    package init(
        accepted: Bool,
        message: String,
        resultCode: HostSoftwareUpdateInstallResultCode?,
        blockReason: HostSoftwareUpdateBlockReason?,
        remediationHint: String?,
        status: HostSoftwareUpdateStatusMessage?
    ) {
        self.accepted = accepted
        self.message = message
        self.resultCode = resultCode
        self.blockReason = blockReason
        self.remediationHint = remediationHint
        self.status = status
    }
}
