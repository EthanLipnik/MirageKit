//
//  MirageHostService+InitialAppWindowBinding.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Per-window initial app-stream binding retries.
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
@MainActor
extension MirageHostService {
    /// Starts one resolved initial app-window binding with bounded retries.
    func startInitialAppWindowBinding(
        app: MirageWire.MirageInstalledApp,
        binding: ResolvedAppWindowBinding,
        preferredSlotIndex: Int,
        clientContext: ClientContext,
        selectRequest: MirageWire.SelectAppMessage,
        targetFrameRate: Int,
        startupAtlasBitrateBudget: Int?,
        mediaMaxPacketSize: Int
    ) async -> InitialAppWindowStartAttemptResult {
        var failureNotes: [String] = []
        let startupDeadline = ContinuousClock.now + appWindowReplacementCooldownDuration
        var slotAttempt = 0
        var preferredWindowID: WindowID? = binding.resolvedWindow.id
        var deprioritizedWindowIDs: Set<WindowID> = []
        var excludedWindowIDs: Set<WindowID> = []
        var currentBinding = binding
        var newWindowRequestAttempts = 0

        while ContinuousClock.now < startupDeadline {
            slotAttempt += 1

            do {
                guard let resolvedBinding = try await resolveCurrentInitialAppWindowBinding(
                    bundleIdentifier: app.bundleIdentifier,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs,
                    excludedWindowIDs: excludedWindowIDs
                ) else {
                    failureNotes.append(
                        "slot \(preferredSlotIndex) attempt \(slotAttempt): no startup-eligible app windows available"
                    )
                    if newWindowRequestAttempts < 2 {
                        newWindowRequestAttempts += 1
                        await appStreamManager.requestNewWindow(
                            bundleIdentifier: app.bundleIdentifier,
                            path: app.path
                        )
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) requested a new \(app.bundleIdentifier) window " +
                                "after binding returned no startup target (request \(newWindowRequestAttempts))"
                        )
                    }
                    if ContinuousClock.now < startupDeadline {
                        do {
                            try await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                        } catch {
                            break
                        }
                    }
                    continue
                }
                currentBinding = resolvedBinding
                preferredWindowID = currentBinding.resolvedWindow.id
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append(
                    "slot \(preferredSlotIndex) attempt \(slotAttempt): binding refresh failed: \(renderedDetail)"
                )
                MirageLogger.error(.host, error: error, message: "Failed to refresh initial app-stream binding: ")
                if ContinuousClock.now < startupDeadline {
                    do {
                        try await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                    } catch {
                        break
                    }
                }
                continue
            }

            do {
                var reservedWindowID: WindowID?
                try reserveInitialAppWindowStartup(windowID: currentBinding.resolvedWindow.id)
                reservedWindowID = currentBinding.resolvedWindow.id
                defer {
                    releaseInitialAppWindowStartupReservation(windowID: reservedWindowID)
                }

                await prepareWindowForStreamingIfNeeded(
                    currentBinding.resolvedWindow,
                    reason: "initial app-stream startup"
                )
                if let reboundBinding = try await resolveCurrentInitialAppWindowBinding(
                    bundleIdentifier: app.bundleIdentifier,
                    preferredWindowID: currentBinding.resolvedWindow.id,
                    deprioritizedWindowIDs: deprioritizedWindowIDs,
                    excludedWindowIDs: excludedWindowIDs,
                    allowedReservedWindowIDs: reservedWindowID.map { Set([$0]) } ?? []
                ) {
                    if reboundBinding.candidate.window.id != currentBinding.candidate.window.id ||
                        reboundBinding.resolvedWindow.id != currentBinding.resolvedWindow.id {
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) rebound startup target " +
                                "candidate \(currentBinding.candidate.window.id)->\(reboundBinding.candidate.window.id) " +
                                "resolved \(currentBinding.resolvedWindow.id)->\(reboundBinding.resolvedWindow.id) after preparation"
                        )
                    }
                    if reboundBinding.resolvedWindow.id != reservedWindowID {
                        try reserveInitialAppWindowStartup(windowID: reboundBinding.resolvedWindow.id)
                        releaseInitialAppWindowStartupReservation(windowID: reservedWindowID)
                        reservedWindowID = reboundBinding.resolvedWindow.id
                    }
                    currentBinding = reboundBinding
                    preferredWindowID = reboundBinding.resolvedWindow.id
                }

                let startedWindow = try await attemptStartInitialAppWindowStream(
                    app: app,
                    startupCandidate: currentBinding.candidate,
                    preferredWindow: currentBinding.resolvedWindow,
                    preferredSlotIndex: preferredSlotIndex,
                    clientContext: clientContext,
                    selectRequest: selectRequest,
                    targetFrameRate: targetFrameRate,
                    requestedBitrateOverride: startupAtlasBitrateBudget,
                    mediaMaxPacketSize: mediaMaxPacketSize
                )
                let succeededWindowIDs = Set([
                    binding.candidate.window.id,
                    currentBinding.candidate.window.id,
                    currentBinding.resolvedWindow.id,
                    startedWindow.windowID,
                ])
                for windowID in succeededWindowIDs {
                    await appStreamManager.noteWindowStartupSucceeded(
                        bundleID: app.bundleIdentifier,
                        windowID: windowID
                    )
                }
                return InitialAppWindowStartAttemptResult(
                    startedWindow: startedWindow,
                    failureNotes: failureNotes
                )
            } catch is CancellationError {
                failureNotes.append("slot \(preferredSlotIndex) cancelled by client")
                return InitialAppWindowStartAttemptResult(startedWindow: nil, failureNotes: failureNotes)
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                let failedWindowIDs = Set([
                    currentBinding.candidate.window.id,
                    currentBinding.resolvedWindow.id,
                ])
                let failedWindowList = failedWindowIDs
                    .sorted(by: <)
                    .map(String.init)
                    .joined(separator: ",")
                let failureCode = windowStreamStartFailureCode(for: error)
                let shouldExcludeFailedWindows = Self.shouldExcludeInitialStartupWindow(after: failureCode)
                failureNotes.append(
                    "slot \(preferredSlotIndex) attempt \(slotAttempt) window(s) \(failedWindowList): \(renderedDetail)"
                )

                let retryable = AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error) &&
                    !shouldExcludeFailedWindows
                let shouldMoveToHiddenInventory = AppStreamStartupFailureClassifier
                    .isNonRetryableVirtualDisplayAllocationError(error)

                for failedWindowID in failedWindowIDs {
                    let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                        bundleID: app.bundleIdentifier,
                        windowID: failedWindowID,
                        retryable: retryable
                    )
                    if case let .retryScheduled(retryAttempt, retryAt) = failureDisposition {
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) retry scheduled for window \(failedWindowID) " +
                                "attempt \(retryAttempt) at \(retryAt)"
                        )
                    }
                }

                if shouldMoveToHiddenInventory {
                    let resolved = currentBinding.resolvedWindow
                    let processID = resolved.application?.id ??
                        currentBinding.candidate.window.application?.id ??
                        0
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
                    for windowID in failedWindowIDs {
                        await appStreamManager.noteWindowStartupSucceeded(
                            bundleID: app.bundleIdentifier,
                            windowID: windowID
                        )
                    }
                    excludedWindowIDs.formUnion(failedWindowIDs)
                    deprioritizedWindowIDs.subtract(failedWindowIDs)
                    MirageLogger.host(
                        "Initial app-stream slot \(preferredSlotIndex) moved window \(resolved.id) to hidden inventory " +
                            "after lifecycle startup failure: \(renderedDetail) (\(currentBinding.candidate.logMetadata))"
                    )
                } else if shouldExcludeFailedWindows {
                    excludedWindowIDs.formUnion(failedWindowIDs)
                    deprioritizedWindowIDs.subtract(failedWindowIDs)
                    if let currentPreferredWindowID = preferredWindowID,
                       failedWindowIDs.contains(currentPreferredWindowID) {
                        preferredWindowID = nil
                    }
                    if failureCode == .windowNotFound, newWindowRequestAttempts < 2 {
                        newWindowRequestAttempts += 1
                        await appStreamManager.requestNewWindow(
                            bundleIdentifier: app.bundleIdentifier,
                            path: app.path
                        )
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) requested a replacement \(app.bundleIdentifier) window " +
                                "after stale startup target(s) \(failedWindowList) (request \(newWindowRequestAttempts))"
                        )
                    }
                    MirageLogger.host(
                        "Initial app-stream slot \(preferredSlotIndex) excluded failed startup window(s) \(failedWindowList): " +
                            "\(renderedDetail) (\(currentBinding.candidate.logMetadata))"
                    )
                } else {
                    if retryable {
                        deprioritizedWindowIDs.formUnion(failedWindowIDs)
                    } else {
                        excludedWindowIDs.formUnion(failedWindowIDs)
                    }
                    MirageLogger.host(
                        "Initial app-stream slot \(preferredSlotIndex) lifecycle retry continuing after startup failure: " +
                            "\(renderedDetail) (\(currentBinding.candidate.logMetadata))"
                    )
                }

                if ContinuousClock.now < startupDeadline {
                    do {
                        try await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                    } catch {
                        break
                    }
                }
            }
        }

        return InitialAppWindowStartAttemptResult(startedWindow: nil, failureNotes: failureNotes)
    }
}

#endif
