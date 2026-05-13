//
//  MessageTypes+AppList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  App-list protocol message definitions.
//

import Foundation

/// Client-to-host request for the installed app list.
package struct AppListRequestMessage: Codable {
    /// Whether host-side app-list caches should be bypassed for this request.
    package let forceRefresh: Bool

    /// Whether host should ignore client icon-presence hints and resend all icon payloads.
    package let forceIconReset: Bool

    /// Preferred icon-priority ordering from the client (pinned/recent first).
    package let priorityBundleIdentifiers: [String]

    /// Bundle identifiers whose icon payloads the client has already persisted.
    package let knownIconBundleIdentifiers: [String]

    /// Client-generated request identifier for correlating metadata + icon updates.
    package let requestID: UUID

    /// Creates an app-list request with normalized bundle identifier hints.
    package init(
        forceRefresh: Bool = false,
        forceIconReset: Bool = false,
        priorityBundleIdentifiers: [String] = [],
        knownIconBundleIdentifiers: [String] = [],
        requestID: UUID = UUID()
    ) {
        self.forceRefresh = forceRefresh
        self.forceIconReset = forceIconReset
        self.priorityBundleIdentifiers = mirageNormalizedBundleIdentifiers(priorityBundleIdentifiers)
        self.knownIconBundleIdentifiers = mirageNormalizedBundleIdentifiers(knownIconBundleIdentifiers)
        self.requestID = requestID
    }
}

/// Host-to-client completion marker for an app-list metadata stream.
package struct AppListCompleteMessage: Codable {
    /// Correlates this completion marker with progress and icon update messages.
    package let requestID: UUID

    /// Total available apps emitted through progress messages for this request.
    package let totalAppCount: Int

    /// Creates an app-list completion marker.
    package init(requestID: UUID, totalAppCount: Int) {
        self.requestID = requestID
        self.totalAppCount = max(0, totalAppCount)
    }
}

/// Host-to-client incremental app-list progress payload.
package struct AppListProgressMessage: Codable {
    /// Correlates this progress snapshot with the active app-list request.
    package let requestID: UUID

    /// Newly discovered app details. Icon payloads are included when the client does not already have them.
    package let apps: [MirageInstalledApp]

    /// Creates an app-list progress payload.
    package init(requestID: UUID, apps: [MirageInstalledApp]) {
        self.requestID = requestID
        self.apps = apps
    }
}
