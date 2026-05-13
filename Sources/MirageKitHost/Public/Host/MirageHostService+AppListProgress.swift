//
//  MirageHostService+AppListProgress.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Returns whether app-list work should pause to keep interactive streaming responsive.
    var isInteractiveWorkloadActiveForAppListRequests: Bool {
        !activeStreams.isEmpty ||
            desktopStreamContext != nil ||
            pendingAppStreamStartCount > 0 ||
            pendingDesktopStreamStartCount > 0
    }

    /// Starts, maintains, or resumes app-list deferral based on the current streaming workload.
    func syncAppListRequestDeferralForInteractiveWorkload() async {
        let shouldDefer = isInteractiveWorkloadActiveForAppListRequests
        if shouldDefer {
            let isBeginningDeferral = !appListRequestDeferredForInteractiveWorkload
            appListRequestDeferredForInteractiveWorkload = true
            cancelAppListRequestForInteractiveWorkload(logCancellation: isBeginningDeferral)
            await appStreamManager.cancelAppListScans()
            return
        }

        if appListRequestDeferredForInteractiveWorkload {
            appListRequestDeferredForInteractiveWorkload = false
            MirageLogger.host("Interactive workload idle; resuming deferred app list request if needed")
            sendPendingAppListRequestIfPossible()
            sendPendingNonEssentialMetadataRequestsIfPossible()
            return
        }

        if appListRequestTask == nil {
            sendPendingAppListRequestIfPossible()
        }
        sendPendingNonEssentialMetadataRequestsIfPossible()
    }

    /// Cancels the active app-list task while preserving the latest pending request.
    func cancelAppListRequestForInteractiveWorkload(logCancellation: Bool = true) {
        if logCancellation, appListRequestTask != nil {
            MirageLogger.host("Cancelling app list request while interactive workload is active")
        }
        appListRequestToken = UUID()
        appListRequestTask?.cancel()
        appListRequestTask = nil
    }

    /// Sends deferred metadata responses that are safe to run when app-list delivery is not blocked.
    func sendPendingNonEssentialMetadataRequestsIfPossible() {
        sendPendingHostHardwareIconRequestIfPossible()
        sendPendingHostWallpaperRequestIfPossible()
        sendPendingHostSoftwareUpdateStatusRequestIfPossible()
    }

    /// Merges a newly received app-list request into the pending request state.
    func updatePendingAppListRequest(
        clientID: UUID,
        requestID: UUID,
        requestedForceRefresh: Bool,
        forceIconReset: Bool,
        priorityBundleIdentifiers: [String],
        knownIconBundleIdentifiers: [String]
    ) {
        let normalizedPriorityBundleIdentifiers = mirageNormalizedBundleIdentifiers(priorityBundleIdentifiers)
        let normalizedKnownIconBundleIdentifiers = mirageNormalizedBundleIdentifiers(knownIconBundleIdentifiers)
        if var pending = pendingAppListRequest, pending.clientID == clientID {
            pending.requestID = requestID
            pending.requestedForceRefresh = pending.requestedForceRefresh || requestedForceRefresh
            pending.forceIconReset = pending.forceIconReset || forceIconReset
            pending.priorityBundleIdentifiers = normalizedPriorityBundleIdentifiers
            pending.knownIconBundleIdentifiers = normalizedKnownIconBundleIdentifiers
            pendingAppListRequest = pending
            return
        }
        pendingAppListRequest = PendingAppListRequest(
            clientID: clientID,
            requestID: requestID,
            requestedForceRefresh: requestedForceRefresh,
            forceIconReset: forceIconReset,
            priorityBundleIdentifiers: normalizedPriorityBundleIdentifiers,
            knownIconBundleIdentifiers: normalizedKnownIconBundleIdentifiers
        )
    }

    /// Starts app-list delivery when the host is ready and no interactive workload is active.
    func sendPendingAppListRequestIfPossible() {
        guard !isInteractiveWorkloadActiveForAppListRequests else {
            appListRequestDeferredForInteractiveWorkload = true
            return
        }
        appListRequestDeferredForInteractiveWorkload = false
        guard let pending = pendingAppListRequest else { return }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingAppListRequest = nil
            return
        }

        appListRequestTask?.cancel()
        if sessionState != .ready {
            MirageLogger.host("Session is \(sessionState); deferring app list request until ready")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await refreshSessionStateIfNeeded()
                if sessionState == .ready {
                    sendPendingAppListRequestIfPossible()
                    return
                }
                await sendSessionState(to: clientContext)
            }
            return
        }
        let forceRefresh = pending.requestedForceRefresh
        let forceIconReset = pending.forceIconReset
        let requestID = pending.requestID
        let priorityBundleIdentifiers = pending.priorityBundleIdentifiers
        let knownIconBundleIdentifiers = pending.knownIconBundleIdentifiers
        let clientID = pending.clientID
        let token = UUID()
        appListRequestToken = token

        appListRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await pruneOrphanedAppSessions()

            let apps = await appStreamManager.installedApps(
                includeIcons: false,
                forceRefresh: forceRefresh
            )
            if Task.isCancelled { return }

            let orderedApps = orderedAppsForAppListProgress(
                apps,
                priorityBundleIdentifiers: priorityBundleIdentifiers,
                knownIconBundleIdentifiers: knownIconBundleIdentifiers
            )
            await sendAppListProgress(
                apps: orderedApps,
                requestID: requestID,
                clientID: clientID,
                token: token,
                forceIconReset: forceIconReset,
                knownIconBundleIdentifiers: knownIconBundleIdentifiers
            )
            if Task.isCancelled { return }

            await sendAppListComplete(
                requestID: requestID,
                appCount: orderedApps.count,
                clientContext: clientContext
            )
            if Task.isCancelled { return }
            if appListRequestToken == token, pendingAppListRequest?.clientID == clientID {
                pendingAppListRequest = nil
            }
        }
    }

    /// Sends the terminal app-list completion message for a request.
    func sendAppListComplete(
        requestID: UUID,
        appCount: Int,
        clientContext: ClientContext
    ) async {
        do {
            let response = AppListCompleteMessage(
                requestID: requestID,
                totalAppCount: appCount
            )
            try await clientContext.send(.appListComplete, content: response)
            recordClientControlSendActivity(clientID: clientContext.client.id)
            MirageLogger.host("Sent app-list completion with \(appCount) apps to \(clientContext.client.name)")
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "App list completion",
                sessionID: clientContext.sessionID
            )
        }
    }

    /// Streams app-list progress batches to the requesting client.
    func sendAppListProgress(
        apps: [MirageInstalledApp],
        requestID: UUID,
        clientID: UUID,
        token: UUID,
        forceIconReset: Bool,
        knownIconBundleIdentifiers: [String]
    ) async {
        let knownIconBundleIdentifierSet = Set(knownIconBundleIdentifiers)
        var batch: [MirageInstalledApp] = []
        batch.reserveCapacity(8)

        for (index, app) in apps.enumerated() {
            guard appListRequestToken == token,
                  pendingAppListRequest?.clientID == clientID,
                  findClientContext(clientID: clientID) != nil else {
                return
            }

            let appWithOptionalIcon = await appListProgressApp(
                app,
                forceIconReset: forceIconReset,
                knownIconBundleIdentifiers: knownIconBundleIdentifierSet
            )
            batch.append(appWithOptionalIcon)

            let batchLimit = index < 24 ? 4 : 8
            if batch.count >= batchLimit {
                await sendAppListProgressBatch(
                    batch,
                    requestID: requestID,
                    clientID: clientID,
                    token: token
                )
                batch.removeAll(keepingCapacity: true)
            }
        }

        guard !batch.isEmpty else { return }
        await sendAppListProgressBatch(
            batch,
            requestID: requestID,
            clientID: clientID,
            token: token
        )
    }

    /// Sends one app-list progress batch if the request is still current.
    func sendAppListProgressBatch(
        _ apps: [MirageInstalledApp],
        requestID: UUID,
        clientID: UUID,
        token: UUID
    ) async {
        guard appListRequestToken == token,
              pendingAppListRequest?.clientID == clientID,
              let clientContext = findClientContext(clientID: clientID) else {
            return
        }
        do {
            let progress = AppListProgressMessage(
                requestID: requestID,
                apps: apps
            )
            try await clientContext.send(.appListProgress, content: progress)
            recordClientControlSendActivity(clientID: clientID)
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "App list progress batch",
                sessionID: clientContext.sessionID
            )
        }
    }

    /// Returns an app-list entry with icon data when the client needs it.
    func appListProgressApp(
        _ app: MirageInstalledApp,
        forceIconReset: Bool,
        knownIconBundleIdentifiers: Set<String>
    ) async -> MirageInstalledApp {
        let normalizedBundleIdentifier = app.bundleIdentifier.lowercased()
        if !forceIconReset,
           knownIconBundleIdentifiers.contains(normalizedBundleIdentifier) {
            return Self.metadataOnlyApp(app)
        }

        guard let iconPayload = await appIconCatalogStore.payload(
            for: app,
            maxPixelSize: 128,
            heifCompressionQuality: 0.72,
            loader: { [appStreamManager] in
                await appStreamManager.iconDataForInstalledApp(
                    atPath: app.path,
                    maxPixelSize: 128,
                    heifCompressionQuality: 0.72
                )
            }
        ) else {
            return Self.metadataOnlyApp(app)
        }

        return MirageInstalledApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            path: app.path,
            iconData: iconPayload.data,
            version: app.version,
            isRunning: app.isRunning,
            isBeingStreamed: app.isBeingStreamed
        )
    }

    /// Orders app-list progress so priority apps and missing icons are delivered first.
    func orderedAppsForAppListProgress(
        _ apps: [MirageInstalledApp],
        priorityBundleIdentifiers: [String],
        knownIconBundleIdentifiers: [String] = []
    ) -> [MirageInstalledApp] {
        guard !apps.isEmpty else { return [] }

        let knownIconBundleIdentifierSet = Set(mirageNormalizedBundleIdentifiers(knownIconBundleIdentifiers))
        var appsByBundleIdentifier: [String: MirageInstalledApp] = [:]
        appsByBundleIdentifier.reserveCapacity(apps.count)
        for app in apps {
            appsByBundleIdentifier[app.bundleIdentifier.lowercased()] = app
        }

        var emittedBundleIdentifiers: Set<String> = []
        var orderedApps: [MirageInstalledApp] = []
        orderedApps.reserveCapacity(apps.count)

        for bundleIdentifier in priorityBundleIdentifiers {
            guard let app = appsByBundleIdentifier[bundleIdentifier] else { continue }
            guard emittedBundleIdentifiers.insert(bundleIdentifier).inserted else { continue }
            orderedApps.append(app)
        }

        let remainingApps = apps
            .filter { !emittedBundleIdentifiers.contains($0.bundleIdentifier.lowercased()) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        orderedApps.append(contentsOf: remainingApps.filter {
            !knownIconBundleIdentifierSet.contains($0.bundleIdentifier.lowercased())
        })
        orderedApps.append(contentsOf: remainingApps.filter {
            knownIconBundleIdentifierSet.contains($0.bundleIdentifier.lowercased())
        })
        return orderedApps
    }

    /// Returns an installed-app payload without icon data.
    static func metadataOnlyApp(_ app: MirageInstalledApp) -> MirageInstalledApp {
        MirageInstalledApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            path: app.path,
            iconData: nil,
            version: app.version,
            isRunning: app.isRunning,
            isBeingStreamed: app.isBeingStreamed
        )
    }

    /// Ends app-stream sessions whose owning clients are no longer connected.
    func pruneOrphanedAppSessions() async {
        let connectedClientIDs = Set(connectedClients.map(\.id))
        await appStreamManager.endSessionsNotOwned(by: connectedClientIDs)
    }
}

#endif
