//
//  MirageHostService+InitialAppWindowStartup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
    /// Result of the first visible-window startup wave for an app stream.
    struct InitialAppWindowStartupResult {
        let windows: [InitialStartedAppWindow]
        let failureSummary: String
    }

    /// App window metadata returned after a window capture stream starts.
    struct InitialStartedAppWindow: Equatable {
        let streamID: StreamID
        let mediaStreamID: StreamID
        let windowID: WindowID
        let title: String?
        let width: Int
        let height: Int
        let isResizable: Bool
        let atlasRegion: MirageMedia.MirageAppAtlasRegion?
        let atlasLayouts: [MirageMedia.MirageAppAtlasLayout]

        /// Wire representation sent to clients in the app stream start response.
        var asWireWindow: MirageWire.AppStreamStartedMessage.AppStreamWindow {
            MirageWire.AppStreamStartedMessage.AppStreamWindow(
                streamID: streamID,
                mediaStreamID: mediaStreamID,
                windowID: windowID,
                title: title,
                width: width,
                height: height,
                isResizable: isResizable,
                atlasRegion: atlasRegion
            )
        }
    }

    /// Result of a single initial app-window binding attempt.
    struct InitialAppWindowStartAttemptResult {
        let startedWindow: InitialStartedAppWindow?
        let failureNotes: [String]
    }

    /// Reserves a window ID while a concurrent startup attempt is binding it.
    func reserveInitialAppWindowStartup(windowID: WindowID) throws {
        if let existingStreamID = activeStreamIDByWindowID[windowID] {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: windowID,
                existingStreamID: existingStreamID
            )
        }
        guard appStreamStartupReservedWindowIDs.insert(windowID).inserted else {
            throw WindowStreamStartError.windowStartupInProgress(windowID: windowID)
        }
    }

    /// Releases a startup reservation once the attempt completes or abandons the window.
    func releaseInitialAppWindowStartupReservation(windowID: WindowID?) {
        guard let windowID else { return }
        appStreamStartupReservedWindowIDs.remove(windowID)
    }

    /// Starts the initial visible app-window capture streams for a selected app.
    func startInitialAppWindowStreams(
        app: MirageWire.MirageInstalledApp,
        client: MirageConnectedClient,
        selectRequest: MirageWire.SelectAppMessage,
        targetFrameRate: Int,
        mediaMaxPacketSize: Int,
        launchOutcome: AppStreamLaunchOutcome
    ) async -> InitialAppWindowStartupResult {
        let maxDiscoveryAttempts = 14
        let maxConcurrentWindowStarts = 2
        var startedWindows: [InitialStartedAppWindow] = []
        var failureNotes: [String] = []
        guard let clientContext = findClientContext(clientID: client.id) else {
            return InitialAppWindowStartupResult(
                windows: [],
                failureSummary: "client session is disconnected or superseded"
            )
        }

        let discovery = await discoverInitialAppWindowCandidates(
            app: app,
            clientContext: clientContext,
            startupRequestID: selectRequest.startupRequestID,
            launchOutcome: launchOutcome,
            maxDiscoveryAttempts: maxDiscoveryAttempts
        )
        let startupCandidates = discovery.candidates
        failureNotes.append(contentsOf: discovery.failureNotes)
        if startupCandidates.isEmpty {
            let summary = failureNotes.suffix(3).joined(separator: "; ")
            return InitialAppWindowStartupResult(
                windows: [],
                failureSummary: summary.isEmpty ? "no startup-eligible app windows became available" : summary
            )
        }

        let bindingPlan: AppWindowBindingPlan
        do {
            let content = try await currentCaptureShareableContent()
            let liveWindows = Self.liveWindowsSnapshot(from: content)
            let activeOwnerClaimedWindowIDs = await platformVirtualDisplayBackend.claimedWindowIDsForActiveOwners(
                activeStreamIDs: Set(activeSessionByStreamID.keys)
            )
            let claimedWindowIDs = Set(activeStreamIDByWindowID.keys)
                .union(activeOwnerClaimedWindowIDs)
                .union(appStreamStartupReservedWindowIDs)
            bindingPlan = AppWindowBindingPlanner.plan(
                candidates: startupCandidates,
                liveWindows: liveWindows,
                claimedWindowIDs: claimedWindowIDs
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedDetail = detail.isEmpty ? String(describing: error) : detail
            failureNotes.append("binding plan snapshot failed: \(renderedDetail)")
            bindingPlan = AppWindowBindingPlan(
                resolvedBindings: [],
                unresolvedCandidates: startupCandidates
            )
        }

        let remappedWindowCount = bindingPlan.resolvedBindings.reduce(into: 0) { partialResult, binding in
            if binding.candidate.window.id != binding.resolvedWindow.id {
                partialResult += 1
            }
        }
        if remappedWindowCount > 0 {
            MirageLogger.host(
                "Initial app-stream startup remapped \(remappedWindowCount) window(s) for \(app.bundleIdentifier)"
            )
        }

        for candidate in bindingPlan.unresolvedCandidates {
            let reason = "no unclaimed live window match in startup wave"
            failureNotes.append("window \(candidate.window.id): \(reason)")
            let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                bundleID: app.bundleIdentifier,
                windowID: candidate.window.id,
                retryable: true
            )
            switch failureDisposition {
            case let .retryScheduled(retryAttempt, retryAt):
                MirageLogger.host(
                    "Initial app-stream startup retry scheduled for \(candidate.window.id) attempt \(retryAttempt) at \(retryAt) (\(candidate.logMetadata))"
                )
            case .terminal:
                await emitWindowStreamFailed(
                    to: clientContext,
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: candidate.window.id,
                    title: initialStreamFailureTitle(for: candidate, appName: app.name),
                    reason: reason,
                    failureCode: .windowNotFound,
                    userMessage: Self.appStreamStartupFailureMessage(appName: app.name)
                )
                MirageLogger.host(
                    "Initial app-stream startup failed permanently for \(candidate.window.id): \(reason) (\(candidate.logMetadata))"
                )
            case .suppressed:
                break
            }
        }

        let initialVisibleSlotCap = await appStreamManager.session(
            bundleIdentifier: app.bundleIdentifier
        )?.maxVisibleSlots ?? 1
        let visibleSlotLimit = max(1, initialVisibleSlotCap)
        let visibleBindings: [(slotIndex: Int, binding: ResolvedAppWindowBinding)] = Array(
            bindingPlan.resolvedBindings
                .prefix(visibleSlotLimit)
                .enumerated()
                .map { index, binding in
                    (slotIndex: index, binding: binding)
                }
        )
        let overflowBindings = Array(bindingPlan.resolvedBindings.dropFirst(visibleSlotLimit))
        let startupAtlasBitrateBudget = await appStreamManager.sharedBitrateBudget(bundleIdentifier: app.bundleIdentifier)
            ?? resolvedAppSessionBitrateBudget(requestedBitrate: selectRequest.bitrate)
        if !overflowBindings.isEmpty {
            for binding in overflowBindings {
                let resolved = binding.resolvedWindow
                let processID = resolved.application?.id ?? binding.candidate.window.application?.id ?? 0
                let isResizable = appStreamManager.checkWindowResizability(
                    processID: processID
                )
                await appStreamManager.upsertHiddenWindow(
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: resolved.id,
                    title: resolved.title,
                    width: Int(resolved.frame.width),
                    height: Int(resolved.frame.height),
                    isResizable: isResizable
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: binding.candidate.window.id
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: resolved.id
                )
            }
            MirageLogger
                .host(
                    "Initial app-stream startup queued \(overflowBindings.count) hidden window(s) for \(app.bundleIdentifier)"
                )
        }

        let startupBatchRanges = Self.appWindowStartupBatchRanges(
            totalCount: visibleBindings.count,
            maxConcurrentWindowStarts: maxConcurrentWindowStarts
        )
        var startedWindowIDs: Set<WindowID> = []
        var startedStreamIDs: Set<StreamID> = []
        for batchRange in startupBatchRanges {
            let batch = Array(visibleBindings[batchRange])
            let batchTasks = batch.map { binding in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return InitialAppWindowStartAttemptResult(
                            startedWindow: nil,
                            failureNotes: ["startup cancelled: host service released"]
                        )
                    }
                    return await startInitialAppWindowBinding(
                        app: app,
                        binding: binding.binding,
                        preferredSlotIndex: binding.slotIndex,
                        clientContext: clientContext,
                        selectRequest: selectRequest,
                        targetFrameRate: targetFrameRate,
                        startupAtlasBitrateBudget: startupAtlasBitrateBudget,
                        mediaMaxPacketSize: mediaMaxPacketSize
                    )
                }
            }
            var batchResults: [InitialAppWindowStartAttemptResult] = []
            batchResults.reserveCapacity(batchTasks.count)
            for task in batchTasks {
                await batchResults.append(task.value)
            }

            for result in batchResults {
                failureNotes.append(contentsOf: result.failureNotes)
                guard let startedWindow = result.startedWindow else { continue }
                let insertedWindow = startedWindowIDs.insert(startedWindow.windowID).inserted
                let insertedStream = startedStreamIDs.insert(startedWindow.streamID).inserted
                if !insertedWindow || !insertedStream {
                    continue
                }
                startedWindows.append(startedWindow)
            }
        }

        let summary = failureNotes.suffix(3).joined(separator: "; ")
        return InitialAppWindowStartupResult(
            windows: startedWindows.sorted { $0.streamID < $1.streamID },
            failureSummary: summary.isEmpty ? "no startup-eligible app windows became available" : summary
        )
    }

}

#endif
