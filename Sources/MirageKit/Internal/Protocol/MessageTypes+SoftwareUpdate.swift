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
    package let currentVersion: String
    package let availableVersion: String?
    package let availableVersionTitle: String?
    /// Unix timestamp milliseconds when the host last checked for updates.
    package let lastCheckedAtMs: Int64?

    package init(
        isSparkleAvailable: Bool,
        isCheckingForUpdates: Bool,
        isInstallInProgress: Bool,
        channel: HostSoftwareUpdateChannel,
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
    package let status: HostSoftwareUpdateStatusMessage?

    package init(
        accepted: Bool,
        message: String,
        status: HostSoftwareUpdateStatusMessage?
    ) {
        self.accepted = accepted
        self.message = message
        self.status = status
    }
}

