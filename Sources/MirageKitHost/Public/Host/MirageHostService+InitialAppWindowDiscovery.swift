//
//  MirageHostService+InitialAppWindowDiscovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    /// Resolves the current best startup binding for an app window request.
    func resolveCurrentInitialAppWindowBinding(
        bundleIdentifier: String,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>,
        allowedReservedWindowIDs: Set<WindowID> = []
    ) async throws -> ResolvedAppWindowBinding? {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleIdentifier) else { return nil }

        let normalizedBundleID = bundleIdentifier.lowercased()
        let catalog = try await AppStreamWindowCatalog.catalog(
            for: [bundleIdentifier],
            captureContentProviderBackend: platformCaptureContentProviderBackend
        )
        let allCandidates = (catalog[normalizedBundleID] ?? [])
            .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
        let candidates = AppStreamWindowCatalog.startupCandidateSelection(from: allCandidates)

        let content = try await currentCaptureShareableContent()
        let liveWindows = Self.liveWindowsSnapshot(from: content)

        let activeOwnerClaimedWindowIDs = await platformVirtualDisplayBackend.claimedWindowIDsForActiveOwners(
            activeStreamIDs: Set(activeSessionByStreamID.keys)
        )
        let reservedWindowIDs = appStreamStartupReservedWindowIDs.subtracting(allowedReservedWindowIDs)
        let claimedWindowIDs = Set(activeStreamIDByWindowID.keys)
            .union(activeOwnerClaimedWindowIDs)
            .union(reservedWindowIDs)
        let visibleWindowIDs = Set(session.windowStreams.keys)

        return Self.resolveInitialAppWindowStartupBinding(
            candidates: candidates,
            liveWindows: liveWindows,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs,
            preferredWindowID: preferredWindowID,
            deprioritizedWindowIDs: deprioritizedWindowIDs,
            excludedWindowIDs: excludedWindowIDs
        )
    }

    /// Discovers startup-eligible windows for an app after launch or activation.
    func discoverInitialAppWindowCandidates(
        app: MirageWire.MirageInstalledApp,
        clientContext: ClientContext,
        startupRequestID: UUID,
        launchOutcome: AppStreamLaunchOutcome,
        maxDiscoveryAttempts: Int
    ) async -> InitialAppWindowDiscoveryResult {
        let normalizedBundleID = app.bundleIdentifier.lowercased()
        var failureNotes: [String] = []
        var startupCandidates: [AppStreamWindowCandidate] = []
        var newWindowRequestAttempts = 0

        for discoveryAttempt in 1 ... maxDiscoveryAttempts {
            if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: startupRequestID) {
                MirageLogger.host("App stream window discovery cancelled by client")
                break
            }

            do {
                let catalog = try await AppStreamWindowCatalog.catalog(
                    for: [app.bundleIdentifier],
                    captureContentProviderBackend: platformCaptureContentProviderBackend
                )
                let allCandidates = (catalog[normalizedBundleID] ?? [])
                    .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
                let auxiliaryCount = allCandidates.count(where: { $0.classification == .auxiliary })
                if auxiliaryCount > 0 {
                    MirageLogger.host(
                        "Initial startup detected \(auxiliaryCount) auxiliary parent-coupled windows for \(app.bundleIdentifier)"
                    )
                }

                let selectedCandidates = AppStreamWindowCatalog.startupCandidateSelection(from: allCandidates)
                guard let session = await appStreamManager.session(bundleIdentifier: app.bundleIdentifier) else {
                    failureNotes.append("discovery \(discoveryAttempt): app session ended before window discovery completed")
                    break
                }

                let activeOwnerClaimedWindowIDs = await platformVirtualDisplayBackend.claimedWindowIDsForActiveOwners(
                    activeStreamIDs: Set(activeSessionByStreamID.keys)
                )
                let claimedWindowIDs = Set(activeStreamIDByWindowID.keys)
                    .union(activeOwnerClaimedWindowIDs)
                    .union(appStreamStartupReservedWindowIDs)
                startupCandidates = Self.lifecycleStartupEligibleCandidates(
                    from: selectedCandidates,
                    visibleWindowIDs: Set(session.windowStreams.keys),
                    claimedWindowIDs: claimedWindowIDs
                )
                if !startupCandidates.isEmpty { break }
                if Self.shouldRequestNewAppWindowOnInitialDiscovery(
                    discoveryAttempt: discoveryAttempt,
                    newWindowRequestAttempts: newWindowRequestAttempts,
                    launchOutcome: launchOutcome,
                    hasLifecycleStartupCandidate: false
                ) {
                    newWindowRequestAttempts += 1
                    await appStreamManager.requestNewWindow(
                        bundleIdentifier: app.bundleIdentifier,
                        path: app.path
                    )
                    MirageLogger.host(
                        "Initial app-stream startup requested a new window for \(app.bundleIdentifier) after discovery attempt \(discoveryAttempt) " +
                            "(request \(newWindowRequestAttempts))"
                    )
                }
                failureNotes.append("discovery \(discoveryAttempt): no startup-eligible app windows found")
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append("discovery \(discoveryAttempt): \(renderedDetail)")
                MirageLogger.error(.host, error: error, message: "Failed app-stream window discovery: ")
            }

            if discoveryAttempt < maxDiscoveryAttempts {
                do {
                    try await Task.sleep(for: Self.initialAppWindowDiscoveryRetryDelay(afterAttempt: discoveryAttempt))
                } catch {
                    break
                }
            }
        }

        return InitialAppWindowDiscoveryResult(
            candidates: startupCandidates,
            failureNotes: failureNotes
        )
    }
}
#endif
