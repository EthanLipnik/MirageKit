//
//  MirageHostService+AppStreamingRequestTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    /// Backoff used while waiting for the first app window to appear after launch.
    nonisolated private static let initialAppWindowDiscoveryRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(350),
        .milliseconds(500),
        .milliseconds(750),
        .seconds(1),
    ]
    /// Discovery attempts at which the host asks an already-running app to open a new window.
    nonisolated private static let initialAppWindowRequestAttempts = [2, 5, 8, 11]
    /// Backoff used when a launch found windows but all visible slots were unavailable.
    nonisolated private static let initialAppWindowSlotRetryDelays: [Duration] = [
        .milliseconds(350),
        .milliseconds(750),
        .seconds(1),
        .seconds(1),
    ]

    enum ExistingSessionWindowStartResult {
        case success(WindowAddedToStreamMessage)
        case cancelled
        case failure(String)
    }

    enum AppWindowSwapContextResult {
        case success(AppWindowSwapContext)
        case failure(AppWindowSwapResultMessage)
    }

    struct AppWindowSwapContext {
        let currentWindowID: WindowID
        let hiddenInfo: AppStreamHiddenWindowInfo
        let streamSession: MirageStreamSession
        let previousWindowInfo: WindowStreamInfo
        let clientContext: ClientContext
    }

    struct SharedDisplayAppWindowSwapRequest {
        let targetSlotStreamID: StreamID
        let targetWindowID: WindowID
        let currentWindowID: WindowID
        let hiddenInfo: AppStreamHiddenWindowInfo
        let streamSession: MirageStreamSession
        let context: StreamContext
    }

    struct SelectAppExistingSessionExpansionRequest {
        let app: MirageInstalledApp
        let client: MirageConnectedClient
        let clientContext: ClientContext
        let selectRequest: SelectAppMessage
        let maxVisibleSlots: Int
        let targetFrameRate: Int
        let mediaMaxPacketSize: Int
    }

    struct InitialAppWindowDiscoveryResult {
        let candidates: [AppStreamWindowCandidate]
        let failureNotes: [String]
    }

    struct WindowStreamingPreparationPlan: Equatable {
        let shouldRestoreWindow: Bool
        let shouldExitFullScreen: Bool
        let settleDelayMilliseconds: Int
    }

    nonisolated static func appWindowStartupBatchRanges(
        totalCount: Int,
        maxConcurrentWindowStarts: Int
    ) -> [Range<Int>] {
        guard totalCount > 0 else { return [] }
        let clampedWidth = max(1, maxConcurrentWindowStarts)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity((totalCount + clampedWidth - 1) / clampedWidth)
        var lowerBound = 0
        while lowerBound < totalCount {
            let upperBound = min(lowerBound + clampedWidth, totalCount)
            ranges.append(lowerBound ..< upperBound)
            lowerBound = upperBound
        }
        return ranges
    }

    nonisolated static func windowStreamingPreparationPlan(
        isOnScreen: Bool,
        isFullScreen: Bool
    ) -> WindowStreamingPreparationPlan {
        let shouldRestoreWindow = !isOnScreen
        let shouldExitFullScreen = isFullScreen
        let activationSettleDelayMilliseconds = 150
        let settleDelayMilliseconds: Int = switch (shouldRestoreWindow, shouldExitFullScreen) {
        case (true, true):
            350
        case (true, false), (false, true):
            250
        case (false, false):
            activationSettleDelayMilliseconds
        }

        return WindowStreamingPreparationPlan(
            shouldRestoreWindow: shouldRestoreWindow,
            shouldExitFullScreen: shouldExitFullScreen,
            settleDelayMilliseconds: settleDelayMilliseconds
        )
    }

    func prepareWindowForStreamingIfNeeded(
        _ window: MirageWindow,
        reason: String
    ) async {
        let plan = Self.windowStreamingPreparationPlan(
            isOnScreen: window.isOnScreen,
            isFullScreen: WindowManager.isWindowFullScreen(window.id)
        )

        let didRestore = plan.shouldRestoreWindow
            ? WindowManager.restoreWindow(window.id)
            : false
        let didExitFullScreen = plan.shouldExitFullScreen
            ? WindowManager.exitFullScreen(window.id)
            : false
        activateWindow(window)
        if plan.settleDelayMilliseconds > 0 {
            do {
                try await Task.sleep(for: .milliseconds(plan.settleDelayMilliseconds))
            } catch {
                return
            }
        }
        MirageLogger.host(
            "Prepared window \(window.id) for streaming (\(reason), restored=\(didRestore), exitedFullScreen=\(didExitFullScreen))"
        )
    }

    nonisolated static func initialAppWindowDiscoveryRetryDelay(
        afterAttempt attempt: Int
    ) -> Duration {
        let normalizedAttempt = max(1, attempt)
        let index = min(normalizedAttempt - 1, initialAppWindowDiscoveryRetryDelays.count - 1)
        return initialAppWindowDiscoveryRetryDelays[index]
    }

    nonisolated static func shouldRequestNewAppWindowOnInitialDiscovery(
        discoveryAttempt: Int,
        newWindowRequestAttempts: Int,
        launchOutcome: AppStreamLaunchOutcome = .launched,
        hasLifecycleStartupCandidate: Bool = false
    ) -> Bool {
        guard !hasLifecycleStartupCandidate else { return false }
        if launchOutcome == .alreadyRunning,
           discoveryAttempt == 1,
           newWindowRequestAttempts == 0 {
            return true
        }
        guard newWindowRequestAttempts < initialAppWindowRequestAttempts.count else { return false }
        return discoveryAttempt >= initialAppWindowRequestAttempts[newWindowRequestAttempts]
    }

    nonisolated static func initialAppWindowSlotRetryDelay(
        afterAttempt attempt: Int
    ) -> Duration {
        let normalizedAttempt = max(1, attempt)
        let index = min(normalizedAttempt - 1, initialAppWindowSlotRetryDelays.count - 1)
        return initialAppWindowSlotRetryDelays[index]
    }

    nonisolated static func resolveInitialAppWindowStartupBinding(
        candidates: [AppStreamWindowCandidate],
        liveWindows: [MirageWindow],
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>
    ) -> ResolvedAppWindowBinding? {
        let orderedCandidates = orderedLifecycleStartupCandidates(
            from: candidates,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs,
            preferredWindowID: preferredWindowID,
            deprioritizedWindowIDs: deprioritizedWindowIDs,
            excludedWindowIDs: excludedWindowIDs
        )
        guard !orderedCandidates.isEmpty else { return nil }

        let unavailableWindowIDs = visibleWindowIDs.union(claimedWindowIDs)
        let bindingPlan = AppWindowBindingPlanner.plan(
            candidates: orderedCandidates,
            liveWindows: liveWindows,
            claimedWindowIDs: unavailableWindowIDs
        )
        return bindingPlan.resolvedBindings.first
    }

    nonisolated static func lifecycleStartupEligibleCandidates(
        from candidates: [AppStreamWindowCandidate],
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID> = []
    ) -> [AppStreamWindowCandidate] {
        orderedLifecycleStartupCandidates(
            from: candidates,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs,
            preferredWindowID: nil,
            deprioritizedWindowIDs: [],
            excludedWindowIDs: excludedWindowIDs
        )
    }

    nonisolated static func orderedLifecycleStartupCandidates(
        from candidates: [AppStreamWindowCandidate],
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>
    ) -> [AppStreamWindowCandidate] {
        candidates
            .enumerated()
            .filter { entry in
                let candidate = entry.element
                guard !excludedWindowIDs.contains(candidate.window.id) else { return false }
                guard candidate.parentWindowID == nil else { return false }
                guard !visibleWindowIDs.contains(candidate.window.id) else { return false }
                guard !claimedWindowIDs.contains(candidate.window.id) else { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lhsPriority = lifecycleStartupCandidatePriority(
                    windowID: lhs.element.window.id,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs
                )
                let rhsPriority = lifecycleStartupCandidatePriority(
                    windowID: rhs.element.window.id,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs
                )
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    nonisolated static func lifecycleStartupCandidatePriority(
        windowID: WindowID,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>
    ) -> Int {
        let isPreferred = preferredWindowID == windowID
        let isDeprioritized = deprioritizedWindowIDs.contains(windowID)

        switch (isPreferred, isDeprioritized) {
        case (true, false):
            return 0
        case (false, false):
            return 1
        case (true, true):
            return 2
        case (false, true):
            return 3
        }
    }

    nonisolated static func liveWindowsSnapshot(from content: SCShareableContent) -> [MirageWindow] {
        content.windows.compactMap { window -> MirageWindow? in
            guard let app = window.owningApplication else { return nil }
            return MirageWindow(
                id: WindowID(window.windowID),
                title: window.title,
                application: MirageApplication(
                    id: app.processID,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.applicationName
                ),
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                windowLayer: window.windowLayer
            )
        }
    }

    nonisolated static func shouldExcludeInitialStartupWindow(
        after failureCode: WindowStreamStartFailureCode
    ) -> Bool {
        switch failureCode {
        case .windowNotFound, .windowAlreadyBound, .windowOwnerConflict, .windowOwnerMismatch:
            true
        case .unknown,
             .virtualDisplayCreationFailed,
             .virtualDisplayUnavailable,
             .windowPlacementFailed,
             .noSavedWindowState,
             .operationTimedOut,
             .runtimeConditionBlocked:
            false
        }
    }

    nonisolated static func appStreamStartupFailureMessage(appName: String) -> String {
        "Could not find a streamable \(appName) window."
    }
}

#endif
