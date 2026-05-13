//
//  MirageClientService+SoftwareUpdateTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation

public extension MirageClientService {
    /// Host software update channel reported by the connected host.
    enum HostSoftwareUpdateChannel: String, Sendable, Codable {
        case release
        case nightly
    }

    /// Host updater automation policy reported by the connected host.
    enum HostSoftwareUpdateAutomationMode: String, Sendable, Codable {
        case metadataOnly
        case autoDownload
        case autoInstall
    }

    /// Current host updater lifecycle state.
    enum HostSoftwareUpdateInstallDisposition: String, Sendable, Codable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case installing
        case completed
        case blocked
        case failed
    }

    /// Reason a host software update request cannot proceed.
    enum HostSoftwareUpdateBlockReason: String, Sendable, Codable {
        case clientUpdatesDisabled
        case hostUpdaterBusy
        case unattendedInstallUnsupported
        case insufficientPermissions
        case authorizationRequired
        case serviceUnavailable
        case policyDenied
        case unknown
    }

    /// Result code returned after a remote host software update install request.
    enum HostSoftwareUpdateInstallResultCode: String, Sendable, Codable {
        case started
        case alreadyInProgress
        case noUpdateAvailable
        case denied
        case blocked
        case failed
        case unavailable
    }

    /// Markup format for host-provided software update release notes.
    enum HostSoftwareUpdateReleaseNotesFormat: String, Sendable, Codable {
        case plainText
        case html
    }

    /// Snapshot of the connected host's software update state.
    struct HostSoftwareUpdateStatus: Sendable, Equatable, Codable {
        /// Whether the host has a working Sparkle updater integration.
        public let isSparkleAvailable: Bool
        /// Whether the host is currently checking for update metadata.
        public let isCheckingForUpdates: Bool
        /// Whether the host is actively installing an update.
        public let isInstallInProgress: Bool
        /// Update channel selected on the host.
        public let channel: HostSoftwareUpdateChannel
        /// Automation policy selected on the host.
        public let automationMode: HostSoftwareUpdateAutomationMode
        /// Current lifecycle phase for the host updater.
        public let installDisposition: HostSoftwareUpdateInstallDisposition
        /// Most recent reason an update operation was blocked, if any.
        public let lastBlockReason: HostSoftwareUpdateBlockReason?
        /// Most recent install request result code, if any.
        public let lastInstallResultCode: HostSoftwareUpdateInstallResultCode?
        /// Whether the current update operation can be cancelled remotely.
        public let canCancelUpdate: Bool
        /// Expected download size in bytes, when known.
        public let downloadExpectedBytes: UInt64?
        /// Bytes downloaded so far.
        public let downloadReceivedBytes: UInt64
        /// Extraction progress from `0...1`, when the host reports it.
        public let extractionProgress: Double?
        /// Short user-facing error summary from the host updater.
        public let lastErrorSummary: String?
        /// Detailed host updater error text, when available.
        public let lastErrorDetails: String?
        /// Version currently running on the host.
        public let currentVersion: String
        /// Version available for install, when one is known.
        public let availableVersion: String?
        /// Display title for the available version.
        public let availableVersionTitle: String?
        /// Short release-note summary for the available update.
        public let releaseNotesSummary: String?
        /// Full release-note body for the available update.
        public let releaseNotesBody: String?
        /// Markup format for `releaseNotesBody`.
        public let releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?
        /// Wall-clock timestamp of the last update check in milliseconds since the Unix epoch.
        public let lastCheckedAtMs: Int64?

        /// Creates a host software-update status snapshot.
        public init(
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

    /// Result returned after requesting a host-side software update install.
    struct HostSoftwareUpdateInstallResult: Sendable, Equatable, Codable {
        /// Whether the host accepted the install request.
        public let accepted: Bool
        /// User-facing result message from the host.
        public let message: String
        /// Machine-readable install result.
        public let resultCode: HostSoftwareUpdateInstallResultCode
        /// Reason the install was blocked, if the request could not proceed.
        public let blockReason: HostSoftwareUpdateBlockReason?
        /// Suggested user action for blocked or failed installs.
        public let remediationHint: String?
        /// Host update status after handling the install request.
        public let status: HostSoftwareUpdateStatus

        /// Creates a host software-update install result.
        public init(
            accepted: Bool,
            message: String,
            resultCode: HostSoftwareUpdateInstallResultCode,
            blockReason: HostSoftwareUpdateBlockReason?,
            remediationHint: String?,
            status: HostSoftwareUpdateStatus
        ) {
            self.accepted = accepted
            self.message = message
            self.resultCode = resultCode
            self.blockReason = blockReason
            self.remediationHint = remediationHint
            self.status = status
        }
    }
}

public extension MirageClientService.HostSoftwareUpdateStatus {
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
