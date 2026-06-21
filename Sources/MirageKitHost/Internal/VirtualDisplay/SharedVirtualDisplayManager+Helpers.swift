//
//  SharedVirtualDisplayManager+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    // MARK: - Private Helpers

    nonisolated func prioritizedVirtualDisplayColorFallbackOrder(requestedColorSpace: MirageColorSpace) -> [MirageColorSpace] {
        var ordered = [requestedColorSpace]
        for candidate in MirageColorSpace.allCases where candidate != requestedColorSpace {
            ordered.append(candidate)
        }
        return ordered
    }

    nonisolated func creationAttempts(
        resolution: CGSize,
        colorSpace: MirageColorSpace,
        policy: DisplayCreationPolicy,
        sourcePixelBudget: VirtualDisplaySourcePixelBudget? = VirtualDisplaySourcePixelBudget.current()
    ) -> [DisplayCreationAttempt] {
        let normalizedRequested = Self.normalizedPixelResolution(resolution)
        var attempts: [DisplayCreationAttempt] = []
        var seenAttemptKeys = Set<String>()

        func appendAttempt(_ attempt: DisplayCreationAttempt) {
            let budgetedAttempt = Self.resourceBudgetedCreationAttempt(attempt, budget: sourcePixelBudget)
            let key = "\(Int(budgetedAttempt.resolution.width))x\(Int(budgetedAttempt.resolution.height))-\(budgetedAttempt.hiDPI ? "retina" : "1x")-\(budgetedAttempt.colorSpace.rawValue)"
            if seenAttemptKeys.insert(key).inserted {
                if budgetedAttempt != attempt {
                    MirageLogger.host(
                        "Virtual display resource budget adjusted creation attempt \(attempt.label): " +
                            "requested=\(Int(attempt.resolution.width))x\(Int(attempt.resolution.height)) " +
                            "resolved=\(Int(budgetedAttempt.resolution.width))x\(Int(budgetedAttempt.resolution.height)) " +
                            "hiDPI=\(budgetedAttempt.hiDPI) budget=\(sourcePixelBudget?.summary ?? "unavailable")"
                    )
                }
                attempts.append(budgetedAttempt)
            }
        }

        switch policy {
        case let .singleAttempt(hiDPI):
            appendAttempt(
                DisplayCreationAttempt(
                    resolution: normalizedRequested,
                    hiDPI: hiDPI,
                    colorSpace: colorSpace,
                    label: hiDPI ? "explicit-retina" : "explicit-1x"
                )
            )
        case .adaptiveRetinaThenFallback1xAndColor:
            let colorFallbackOrder = prioritizedVirtualDisplayColorFallbackOrder(requestedColorSpace: colorSpace)
            let fallback1x = Self.fallbackResolution(for: normalizedRequested)

            for candidateColorSpace in colorFallbackOrder {
                appendAttempt(
                    DisplayCreationAttempt(
                        resolution: normalizedRequested,
                        hiDPI: true,
                        colorSpace: candidateColorSpace,
                        label: "requested-retina-\(candidateColorSpace.rawValue)"
                    )
                )
            }

            for candidateColorSpace in colorFallbackOrder {
                appendAttempt(
                    DisplayCreationAttempt(
                        resolution: fallback1x,
                        hiDPI: false,
                        colorSpace: candidateColorSpace,
                        label: "requested-1x-\(candidateColorSpace.rawValue)"
                    )
                )
            }
        }

        return attempts
    }

    private func resolvedScaleFactor(displayID: CGDirectDisplayID, fallback: CGFloat) -> CGFloat {
        if let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID),
           modeSizes.logical.width > 0,
           modeSizes.logical.height > 0,
           modeSizes.pixel.width > 0,
           modeSizes.pixel.height > 0 {
            let scale = modeSizes.pixel.width / modeSizes.logical.width
            if scale > 0 { return scale }
        }
        return fallback
    }

    func notifyGenerationChangeIfNeeded(previousGeneration: UInt64) {
        guard previousGeneration > 0 else { return }
        guard let display = sharedDisplay else { return }
        guard display.generation != previousGeneration else { return }
        MirageLogger.host("Shared display generation advanced: \(previousGeneration) -> \(display.generation)")
        generationChangeHandler?(snapshot(from: display), previousGeneration)
    }

    func waitForSpaceAssignment(
        displayID: CGDirectDisplayID,
        timeoutMs: Int = 1500,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async -> CGSSpaceID? {
        let clampedTimeoutMs = startupBudget?.boundedDelayMilliseconds(max(0, timeoutMs)) ?? max(0, timeoutMs)
        let deadline = Date().addingTimeInterval(Double(clampedTimeoutMs) / 1000.0)
        while Date() < deadline {
            if startupBudget?.isExpired == true { return nil }
            let spaceID = CGVirtualDisplayBridge.space(for: displayID)
            if spaceID != 0 { return spaceID }
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) { return nil }
            let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(50) ?? 50
            do {
                try await Task.sleep(for: .milliseconds(boundedDelayMs))
            } catch {
                return nil
            }
        }
        return nil
    }

    func updateDisplayInPlace(
        display: ManagedDisplayContext,
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async -> ManagedDisplayContext? {
        guard display.colorSpace == colorSpace else { return nil }

        let useHiDPI = display.scaleFactor > 1.5
        let normalizedResolution = Self.normalizedPixelResolution(newResolution)
        let expectedLogicalResolution = useHiDPI
            ? Self.logicalResolution(for: normalizedResolution, scaleFactor: display.scaleFactor)
            : normalizedResolution
        let success = await withDisplayMutation(kind: .virtualDisplayModeUpdate) {
            CGVirtualDisplayBridge.updateDisplayResolution(
                display: display.displayRef.value,
                width: Int(normalizedResolution.width),
                height: Int(normalizedResolution.height),
                refreshRate: Double(refreshRate),
                hiDPI: useHiDPI,
                isFallbackProbe: true
            )
        }
        guard success else { return nil }

        let validationOutcome = await validateDisplayMode(
            displayID: display.displayID,
            expectedLogicalResolution: expectedLogicalResolution,
            expectedPixelResolution: normalizedResolution,
            expectedRefreshRate: Double(refreshRate)
        )
        guard validationOutcome == .ready,
              let observedMode = validatedObservedDisplayMode(
                  requestedResolution: normalizedResolution,
                  requestedRefreshRate: refreshRate,
                  observedMode: observedDisplayMode(displayID: display.displayID)
              ) else {
            return nil
        }

        let updatedScaleFactor = resolvedScaleFactor(displayID: display.displayID, fallback: display.scaleFactor)
        let updatedDisplay = ManagedDisplayContext(
            displayID: display.displayID,
            spaceID: display.spaceID,
            resolution: observedMode.pixelResolution,
            scaleFactor: updatedScaleFactor,
            refreshRate: observedMode.refreshRate,
            colorSpace: display.colorSpace,
            displayP3CoverageStatus: display.displayP3CoverageStatus,
            generation: display.generation,
            createdAt: display.createdAt,
            displayRef: display.displayRef
        )

        return updatedDisplay
    }

    func updateDisplayInPlace(
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async -> Bool {
        guard let display = sharedDisplay else { return false }
        guard let updatedDisplay = await updateDisplayInPlace(
            display: display,
            newResolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace
        ) else {
            return false
        }
        sharedDisplay = updatedDisplay
        return true
    }

    /// Create a managed virtual display instance.
    func createDisplay(
        resolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        displayNameOverride: String? = nil,
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async throws -> ManagedDisplayContext {
        if displayCounter == 0 {
            displayCounter = 1
        }
        displayGeneration &+= 1
        let generation = displayGeneration
        let displayName = displayNameOverride ?? "Mirage Shared Display (#\(displayCounter))"

        let normalizedRequested = Self.normalizedPixelResolution(resolution)
        var lastValidationOutcome: DisplayValidationOutcome?
        var retinaCollapseRequiresOneXRetry = false
        let dedupedAttempts = creationAttempts(
            resolution: normalizedRequested,
            colorSpace: colorSpace,
            policy: creationPolicy
        )

        for attempt in dedupedAttempts {
            try startupBudget?.checkAvailable()
            if retinaCollapseRequiresOneXRetry, attempt.hiDPI {
                MirageLogger.host(
                    "Skipping Retina virtual-display retry \(attempt.label) because the previous Retina request collapsed to 1x"
                )
                continue
            }
            let requestedResolution = attempt.resolution

            let creationResult = await withDisplayMutation(kind: .virtualDisplayCreate) {
                CGVirtualDisplayBridge.createVirtualDisplay(
                    name: displayName,
                    width: Int(requestedResolution.width),
                    height: Int(requestedResolution.height),
                    refreshRate: Double(refreshRate),
                    hiDPI: attempt.hiDPI,
                    colorSpace: attempt.colorSpace,
                    startupBudget: startupBudget
                )
            }
            guard let displayContext = creationResult.context else {
                if creationResult.failedBecauseRetinaCollapsedToOneX, attempt.hiDPI {
                    retinaCollapseRequiresOneXRetry = true
                    MirageLogger.host(
                        "Retina virtual-display request collapsed to 1x for \(attempt.label); trying the next 1x creation rung"
                    )
                    continue
                }
                MirageLogger.host(
                    "Virtual display create failed for \(attempt.label) at \(Int(requestedResolution.width))x\(Int(requestedResolution.height)), color=\(attempt.colorSpace.displayName)"
                )
                continue
            }

            let acceptedCollapsedOneX = creationResult.modeActivationResult == .retinaCollapsedToOneX
            let modeSizesAtCreate = CGVirtualDisplayBridge.currentDisplayModeSizes(displayContext.displayID)
            let observedPixelDimensionsAtCreate = CGSize(
                width: CGFloat(CGDisplayPixelsWide(displayContext.displayID)),
                height: CGFloat(CGDisplayPixelsHigh(displayContext.displayID))
            )
            let observedBoundsAtCreate = CGDisplayBounds(displayContext.displayID).size
            let collapsedOneXPixel: CGSize? = if acceptedCollapsedOneX {
                if observedPixelDimensionsAtCreate.width > 0, observedPixelDimensionsAtCreate.height > 0 {
                    Self.normalizedPixelResolution(observedPixelDimensionsAtCreate)
                } else if observedBoundsAtCreate.width > 0, observedBoundsAtCreate.height > 0 {
                    Self.normalizedPixelResolution(observedBoundsAtCreate)
                } else {
                    Self.fallbackResolution(for: requestedResolution)
                }
            } else {
                nil
            }
            let collapsedModeSizesAtCreate: CGVirtualDisplayBridge.DisplayModeSizes? = if acceptedCollapsedOneX,
                                                                                          let modeSizesAtCreate,
                                                                                          let collapsedOneXPixel,
                                                                                          Self.resolutionsMatch(modeSizesAtCreate.pixel, collapsedOneXPixel),
                                                                                          Self.resolutionsMatch(modeSizesAtCreate.logical, collapsedOneXPixel) {
                modeSizesAtCreate
            } else {
                nil
            }
            let effectiveScaleHint: CGFloat = if let modeSizesAtCreate,
                                                 !acceptedCollapsedOneX,
                                                 modeSizesAtCreate.logical.width > 0 {
                max(1.0, modeSizesAtCreate.pixel.width / modeSizesAtCreate.logical.width)
            } else if let collapsedModeSizesAtCreate,
                      collapsedModeSizesAtCreate.logical.width > 0 {
                max(1.0, collapsedModeSizesAtCreate.pixel.width / collapsedModeSizesAtCreate.logical.width)
            } else if acceptedCollapsedOneX {
                1.0
            } else {
                attempt.hiDPI ? 2.0 : 1.0
            }
            let effectivePixel = if acceptedCollapsedOneX {
                collapsedModeSizesAtCreate?.pixel ?? collapsedOneXPixel ?? requestedResolution
            } else {
                modeSizesAtCreate?.pixel ?? requestedResolution
            }
            let effectiveLogical = SharedVirtualDisplayManager.logicalResolution(
                for: effectivePixel,
                scaleFactor: effectiveScaleHint
            )

            guard await CGVirtualDisplayBridge.waitForDisplayReady(
                displayContext.displayID,
                expectedResolution: effectiveLogical,
                alternateExpectedResolution: effectivePixel,
                startupBudget: startupBudget
            ) != nil else {
                await destroyAttemptDisplay(displayContext)
                continue
            }

            let observedModeAfterReady = observedDisplayMode(displayID: displayContext.displayID)
            if acceptedCollapsedOneX {
                MirageLogger.host(
                    "Skipping post-ready virtual display mode enforcement for \(displayContext.displayID); Retina request already settled as stable 1x \(Int(effectivePixel.width))x\(Int(effectivePixel.height))"
                )
            } else if Self.needsPostReadyModeEnforcement(
                observedMode: observedModeAfterReady,
                expectedPixelResolution: effectivePixel,
                expectedRefreshRate: Double(refreshRate)
            ) {
                let enforceHiDPI = effectiveScaleHint > 1.5
                let enforced = await withDisplayMutation(kind: .virtualDisplayModeUpdate) {
                    CGVirtualDisplayBridge.updateDisplayResolution(
                        display: displayContext.display,
                        width: Int(effectivePixel.width.rounded()),
                        height: Int(effectivePixel.height.rounded()),
                        refreshRate: Double(refreshRate),
                        hiDPI: enforceHiDPI,
                        isFallbackProbe: true
                    )
                }
                guard enforced else {
                    await destroyAttemptDisplay(displayContext)
                    continue
                }
            } else {
                MirageLogger.host(
                    "Skipping post-ready virtual display mode enforcement for \(displayContext.displayID); observed mode already matches \(Int(effectivePixel.width))x\(Int(effectivePixel.height)) @ \(refreshRate)Hz"
                )
            }

            guard let spaceID = await waitForSpaceAssignment(
                displayID: displayContext.displayID,
                startupBudget: startupBudget
            ) else {
                await destroyAttemptDisplay(displayContext)
                throw SharedDisplayError.spaceNotFound(displayContext.displayID)
            }

            let modeSizesAfterEnforce = CGVirtualDisplayBridge.currentDisplayModeSizes(displayContext.displayID)
            let validatedScaleHint: CGFloat = if let modeSizesAfterEnforce,
                                                 modeSizesAfterEnforce.logical.width > 0 {
                max(1.0, modeSizesAfterEnforce.pixel.width / modeSizesAfterEnforce.logical.width)
            } else {
                effectiveScaleHint
            }
            let validatedPixelResolution = modeSizesAfterEnforce?.pixel ?? effectivePixel
            let validatedLogicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: validatedPixelResolution,
                scaleFactor: validatedScaleHint
            )

            let validationOutcome = await validateDisplayMode(
                displayID: displayContext.displayID,
                expectedLogicalResolution: validatedLogicalResolution,
                expectedPixelResolution: validatedPixelResolution,
                expectedRefreshRate: Double(refreshRate),
                startupBudget: startupBudget
            )
            guard validationOutcome == .ready else {
                lastValidationOutcome = validationOutcome
                if case .screenCaptureKitVisibilityDelayed = validationOutcome {
                    MirageLogger.host(
                        "Virtual display \(displayContext.displayID) activated but ScreenCaptureKit visibility lagged beyond validation budget"
                    )
                }
                await destroyAttemptDisplay(displayContext)
                continue
            }

            let displayScaleFactor = resolvedScaleFactor(
                displayID: displayContext.displayID,
                fallback: validatedScaleHint
            )
            let observedMode = validatedObservedDisplayMode(
                requestedResolution: validatedPixelResolution,
                requestedRefreshRate: refreshRate,
                observedMode: observedDisplayMode(displayID: displayContext.displayID)
            )
            let managedContext = ManagedDisplayContext(
                displayID: displayContext.displayID,
                spaceID: spaceID,
                resolution: observedMode?.pixelResolution ?? validatedPixelResolution,
                scaleFactor: displayScaleFactor,
                refreshRate: observedMode?.refreshRate ?? displayContext.refreshRate,
                colorSpace: displayContext.colorSpace,
                displayP3CoverageStatus: displayContext.displayP3CoverageStatus,
                generation: generation,
                createdAt: Date(),
                displayRef: UncheckedSendableBox(displayContext.display)
            )
            if acceptedCollapsedOneX {
                MirageLogger.host(
                    "Created shared virtual display using collapsed Retina 1x fallback at \(Int(validatedPixelResolution.width))x\(Int(validatedPixelResolution.height)) px, color=\(managedContext.colorSpace.displayName)"
                )
            } else if !attempt.hiDPI {
                MirageLogger.host(
                    "Created shared virtual display using non-Retina fallback at \(Int(validatedPixelResolution.width))x\(Int(validatedPixelResolution.height)) px, color=\(attempt.colorSpace.displayName)"
                )
            }

            if managedContext.colorSpace != colorSpace {
                if colorSpace == .displayP3, managedContext.colorSpace == .sRGB {
                    MirageLogger.host(
                        "Virtual display color fallback engaged: requested Display P3, effectiveColor=sRGB, coverage=\(managedContext.displayP3CoverageStatus.rawValue)"
                    )
                } else {
                    MirageLogger.host(
                        "Virtual display color fallback engaged: requested \(colorSpace.displayName), using \(managedContext.colorSpace.displayName)"
                    )
                }
            }
            if colorSpace == .displayP3,
               managedContext.displayP3CoverageStatus.requiresCanonicalCoverageWarning {
                MirageLogger.host(
                    "Virtual display color fallback engaged: requested Display P3, coverage=\(managedContext.displayP3CoverageStatus.rawValue), effectiveColor=\(managedContext.colorSpace.displayName)"
                )
            }
            let aspectDelta = Self.aspectRelativeDelta(
                requested: normalizedRequested,
                candidate: validatedPixelResolution
            )
            let aspectDeltaPercent = Double(aspectDelta * 100.0)
                .formatted(.number.precision(.fractionLength(3)))
            MirageLogger.host(
                "Virtual display selection decision: rung=\(attempt.label), requested=\(Int(normalizedRequested.width))x\(Int(normalizedRequested.height)), resolved=\(Int(validatedPixelResolution.width))x\(Int(validatedPixelResolution.height)), scale=\(displayScaleFactor), aspectDelta=\(aspectDeltaPercent)%"
            )

            return managedContext
        }

        if case let .screenCaptureKitVisibilityDelayed(displayID) = lastValidationOutcome {
            throw SharedDisplayError.screenCaptureKitVisibilityDelayed(displayID)
        }

        if retinaCollapseRequiresOneXRetry {
            throw SharedDisplayError.retinaCollapsedToOneX(normalizedRequested)
        }

        let attemptSummary = dedupedAttempts.map(\.label).joined(separator: ", ")
        throw SharedDisplayError.creationFailed(
            "Virtual display failed activation (\(attemptSummary))"
        )
    }

    /// Recreate the display at a new resolution.
    func recreateDisplay(
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        preferFastRecreate: Bool = false,
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async throws -> ManagedDisplayContext {
        await destroyDisplay(removalWaitMs: preferFastRecreate ? 250 : 1500)
        try startupBudget?.checkAvailable()
        let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(50) ?? 50
        try await Task.sleep(for: .milliseconds(boundedDelayMs))
        return try await createDisplay(
            resolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace,
            creationPolicy: creationPolicy,
            startupBudget: startupBudget
        )
    }

}
#endif
