//
//  MirageClientService+AppListPreparation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import ImageIO
import MirageKit

extension MirageClientService {
    /// Reusable icon payload retained from an earlier app-list snapshot.
    struct AppIconPayload: Sendable {
        /// Encoded image bytes that previously passed payload validation.
        let iconData: Data
    }

    /// Result of validating and normalizing app-list progress off the main actor.
    struct PreparedAppListProgress: Sendable {
        /// Apps ready to merge into the client's incremental app-list state.
        let apps: [MirageInstalledApp]

        /// Icon payloads dropped during preparation because they were malformed.
        let rejectedIcons: [RejectedAppIconPayload]
    }

    /// Describes an app-list icon payload rejected during preparation.
    struct RejectedAppIconPayload: Sendable {
        /// Bundle identifier from the rejected app payload.
        let bundleIdentifier: String

        /// Validation reason that made the icon unusable.
        let reason: RejectedAppIconReason
    }

    /// Reason an app-list icon payload could not be reused.
    enum RejectedAppIconReason: Sendable {
        /// The icon bytes could not be decoded as an image.
        case invalidImagePayload

        /// Human-readable reason text for host/client logs.
        var logDescription: String {
            switch self {
            case .invalidImagePayload:
                "invalid image payload"
            }
        }
    }

    /// Rebuilds the incremental app-list accumulator from a complete app snapshot.
    func rebuildAvailableAppAccumulator(from apps: [MirageInstalledApp]) {
        availableAppsByBundleIdentifier.removeAll(keepingCapacity: true)
        orderedAvailableAppBundleIdentifiers.removeAll(keepingCapacity: true)
        activeAppListReceivedBundleIdentifiers.removeAll(keepingCapacity: true)

        for app in apps {
            let normalizedBundleID = app.bundleIdentifier.lowercased()
            guard !normalizedBundleID.isEmpty else { continue }
            if availableAppsByBundleIdentifier[normalizedBundleID] == nil {
                orderedAvailableAppBundleIdentifiers.append(normalizedBundleID)
            }
            availableAppsByBundleIdentifier[normalizedBundleID] = app
        }
    }

    /// Captures reusable app icon payloads before a detached app-list preparation pass.
    func availableIconPayloadsByBundleIdentifierSnapshot() -> [String: AppIconPayload] {
        var iconPayloadsByBundleIdentifier: [String: AppIconPayload] = [:]
        iconPayloadsByBundleIdentifier.reserveCapacity(availableAppsByBundleIdentifier.count)

        for (bundleIdentifier, app) in availableAppsByBundleIdentifier {
            guard let iconData = app.iconData else { continue }
            iconPayloadsByBundleIdentifier[bundleIdentifier] = AppIconPayload(iconData: iconData)
        }
        return iconPayloadsByBundleIdentifier
    }

    /// Validates and merges app-list icon payloads off the main actor.
    nonisolated static func prepareAppListProgressApps(
        _ apps: [MirageInstalledApp],
        previousIconsByBundleIdentifier: [String: AppIconPayload]
    ) -> PreparedAppListProgress {
        var preparedApps: [MirageInstalledApp] = []
        preparedApps.reserveCapacity(apps.count)
        var rejectedIcons: [RejectedAppIconPayload] = []

        for app in apps {
            let normalizedBundleIdentifier = app.bundleIdentifier.lowercased()

            if let iconData = app.iconData {
                guard isValidImagePayload(iconData) else {
                    rejectedIcons.append(
                        RejectedAppIconPayload(
                            bundleIdentifier: app.bundleIdentifier,
                            reason: .invalidImagePayload
                        )
                    )
                    preparedApps.append(
                        appWithFallbackIconData(
                            app,
                            previousIcon: previousIconsByBundleIdentifier[normalizedBundleIdentifier]
                        )
                    )
                    continue
                }

                preparedApps.append(
                    appWithUpdatedIconData(
                        app,
                        iconData: iconData
                    )
                )
            } else {
                preparedApps.append(
                    appWithFallbackIconData(
                        app,
                        previousIcon: previousIconsByBundleIdentifier[normalizedBundleIdentifier]
                    )
                )
            }
        }

        return PreparedAppListProgress(apps: preparedApps, rejectedIcons: rejectedIcons)
    }

    nonisolated private static func appWithFallbackIconData(
        _ app: MirageInstalledApp,
        previousIcon: AppIconPayload?
    ) -> MirageInstalledApp {
        guard let previousIcon,
              isValidImagePayload(previousIcon.iconData) else {
            return appWithUpdatedIconData(app, iconData: nil)
        }
        return appWithUpdatedIconData(
            app,
            iconData: previousIcon.iconData
        )
    }

    nonisolated private static func appWithUpdatedIconData(
        _ app: MirageInstalledApp,
        iconData: Data?
    ) -> MirageInstalledApp {
        MirageInstalledApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            path: app.path,
            iconData: iconData,
            version: app.version,
            isRunning: app.isRunning,
            isBeingStreamed: app.isBeingStreamed
        )
    }

    nonisolated private static func isValidImagePayload(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
