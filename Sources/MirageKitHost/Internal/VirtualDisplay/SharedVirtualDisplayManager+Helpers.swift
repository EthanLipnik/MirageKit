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

    enum DisplayValidationOutcome: Sendable, Equatable {
        case ready
        case screenCaptureKitVisibilityDelayed(CGDirectDisplayID)
        case modeMismatch
    }

    struct DisplayCreationAttempt: Sendable {
        let resolution: CGSize
        let hiDPI: Bool
        let colorSpace: MirageColorSpace
        let label: String
    }

    func prioritizedVirtualDisplayColorFallbackOrder(requestedColorSpace: MirageColorSpace) -> [MirageColorSpace] {
        var ordered = [requestedColorSpace]
        for candidate in MirageColorSpace.allCases where candidate != requestedColorSpace {
            ordered.append(candidate)
        }
        return ordered
    }

    static func logicalResolution(for pixelResolution: CGSize, scaleFactor: CGFloat = 2.0) -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else { return pixelResolution }
        let scale = max(1.0, scaleFactor)
        return CGSize(
            width: pixelResolution.width / scale,
            height: pixelResolution.height / scale
        )
    }

    static func fallbackResolution(for retinaResolution: CGSize) -> CGSize {
        let width = CGFloat(StreamContext.alignedEvenPixel(max(2.0, retinaResolution.width / 2.0)))
        let height = CGFloat(StreamContext.alignedEvenPixel(max(2.0, retinaResolution.height / 2.0)))
        return CGSize(width: width, height: height)
    }

    private static func normalizedPixelResolution(_ resolution: CGSize) -> CGSize {
        CGSize(
            width: CGFloat(StreamContext.alignedEvenPixel(max(2.0, resolution.width))),
            height: CGFloat(StreamContext.alignedEvenPixel(max(2.0, resolution.height)))
        )
    }

    private func creationAttempts(
        resolution: CGSize,
        colorSpace: MirageColorSpace,
        policy: DisplayCreationPolicy
    ) -> [DisplayCreationAttempt] {
        let normalizedRequested = Self.normalizedPixelResolution(resolution)
        var attempts: [DisplayCreationAttempt] = []
        var seenAttemptKeys = Set<String>()

        func appendAttempt(_ attempt: DisplayCreationAttempt) {
            let key = "\(Int(attempt.resolution.width))x\(Int(attempt.resolution.height))-\(attempt.hiDPI ? "retina" : "1x")-\(attempt.colorSpace.rawValue)"
            if seenAttemptKeys.insert(key).inserted {
                attempts.append(attempt)
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

    static func aspectRelativeDelta(requested: CGSize, candidate: CGSize) -> CGFloat {
        guard requested.width > 0,
              requested.height > 0,
              candidate.width > 0,
              candidate.height > 0 else {
            return .greatestFiniteMagnitude
        }
        let requestedAspect = requested.width / requested.height
        let candidateAspect = candidate.width / candidate.height
        guard requestedAspect > 0, candidateAspect > 0 else {
            return .greatestFiniteMagnitude
        }
        return abs(requestedAspect - candidateAspect) / requestedAspect
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

    func dedicatedDisplayName(for streamID: StreamID) -> String {
        "Mirage Stream Display (\(streamID))"
    }

    private func dedicatedInsetCacheKey(
        scaleFactor: CGFloat,
        colorSpace: MirageColorSpace
    ) -> DedicatedInsetCacheKey {
        let normalizedScale = max(1.0, scaleFactor)
        let bucket = Int((normalizedScale * 100).rounded())
        return DedicatedInsetCacheKey(colorSpace: colorSpace, scaleBucket: bucket)
    }

    func cachedDedicatedInsetsPixels(
        scaleFactor: CGFloat,
        colorSpace: MirageColorSpace
    ) -> CGSize {
        dedicatedInsetsByKey[dedicatedInsetCacheKey(scaleFactor: scaleFactor, colorSpace: colorSpace)] ?? .zero
    }

    func cacheDedicatedInsetsPixels(
        _ insets: CGSize,
        scaleFactor: CGFloat,
        colorSpace: MirageColorSpace
    ) {
        guard insets.width >= 0, insets.height >= 0 else { return }
        let sanitized = CGSize(width: ceil(insets.width), height: ceil(insets.height))
        dedicatedInsetsByKey[dedicatedInsetCacheKey(scaleFactor: scaleFactor, colorSpace: colorSpace)] = sanitized
    }

    /// Check if display needs to be resized
    func needsResize(currentResolution: CGSize, targetResolution: CGSize) -> Bool {
        let widthDiff = abs(currentResolution.width - targetResolution.width)
        let heightDiff = abs(currentResolution.height - targetResolution.height)
        // Allow small tolerance (2 pixels) for rounding differences
        return widthDiff > 2 || heightDiff > 2
    }

    func validateDisplayMode(
        displayID: CGDirectDisplayID,
        expectedLogicalResolution: CGSize,
        expectedPixelResolution: CGSize
    )
    async -> DisplayValidationOutcome {
        guard expectedLogicalResolution.width > 0,
              expectedLogicalResolution.height > 0,
              expectedPixelResolution.width > 0,
              expectedPixelResolution.height > 0 else { return .ready }

        let maxAttempts = 6
        var delayMs = 80
        var sawScreenCaptureKitDelay = false

        for attempt in 1 ... maxAttempts {
            let bounds = CGDisplayBounds(displayID)
            let boundsReady = bounds.width > 0 && bounds.height > 0
            let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID)

            do {
                let scDisplay = try await findSCDisplay(displayID: displayID, maxAttempts: 1)
                let scSize = CGSize(width: CGFloat(scDisplay.display.width), height: CGFloat(scDisplay.display.height))
                let modeLogicalSize = modeSizes?.logical ?? .zero
                let modePixelSize = modeSizes?.pixel ?? .zero

                let scMatchesLogical = abs(scSize.width - expectedLogicalResolution.width) <= 1 &&
                    abs(scSize.height - expectedLogicalResolution.height) <= 1
                let scMatchesPixel = abs(scSize.width - expectedPixelResolution.width) <= 1 &&
                    abs(scSize.height - expectedPixelResolution.height) <= 1

                let boundsMatchesLogical = abs(bounds.width - expectedLogicalResolution.width) <= 1 &&
                    abs(bounds.height - expectedLogicalResolution.height) <= 1
                let boundsMatchesPixel = abs(bounds.width - expectedPixelResolution.width) <= 1 &&
                    abs(bounds.height - expectedPixelResolution.height) <= 1

                let modeMatchesLogical = abs(modeLogicalSize.width - expectedLogicalResolution.width) <= 1 &&
                    abs(modeLogicalSize.height - expectedLogicalResolution.height) <= 1
                let modeMatchesPixel = abs(modePixelSize.width - expectedPixelResolution.width) <= 1 &&
                    abs(modePixelSize.height - expectedPixelResolution.height) <= 1

                let sizeMatches = scMatchesLogical || scMatchesPixel || boundsMatchesLogical || boundsMatchesPixel
                let modeMatches = modeMatchesLogical && modeMatchesPixel
                let expectsOneX = abs(expectedLogicalResolution.width - expectedPixelResolution.width) <= 1 &&
                    abs(expectedLogicalResolution.height - expectedPixelResolution.height) <= 1

                if boundsReady, sizeMatches, modeMatches {
                    return .ready
                }

                if expectsOneX, boundsReady, sizeMatches {
                    MirageLogger
                        .host(
                            "Virtual display \(displayID) accepted using lenient 1x validation: " +
                                "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                                "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), " +
                                "expected=\(expectedPixelResolution)"
                        )
                    return .ready
                }

                MirageLogger
                    .host(
                        "Virtual display \(displayID) size mismatch (attempt \(attempt)/\(maxAttempts)): " +
                            "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                            "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), " +
                            "expectedLogical=\(expectedLogicalResolution), expectedPixel=\(expectedPixelResolution)"
                    )
            } catch let error as SharedDisplayError {
                switch error {
                case .noActiveDisplay, .scDisplayNotFound:
                    sawScreenCaptureKitDelay = true
                default:
                    break
                }
                MirageLogger
                    .host(
                        "Virtual display \(displayID) size validation failed (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
            } catch {
                MirageLogger
                    .host(
                        "Virtual display \(displayID) size validation failed (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(delayMs))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        if sawScreenCaptureKitDelay {
            return .screenCaptureKitVisibilityDelayed(displayID)
        }
        return .modeMismatch
    }

    func waitForDisplayRemoval(displayID: CGDirectDisplayID, timeoutMs: Int = 1500) async {
        let clampedTimeoutMs = max(0, timeoutMs)
        let deadline = Date().addingTimeInterval(Double(clampedTimeoutMs) / 1000.0)
        while Date() < deadline {
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func waitForSpaceAssignment(
        displayID: CGDirectDisplayID,
        timeoutMs: Int = 1500
    )
    async -> CGSSpaceID? {
        let clampedTimeoutMs = max(0, timeoutMs)
        let deadline = Date().addingTimeInterval(Double(clampedTimeoutMs) / 1000.0)
        while Date() < deadline {
            let spaceID = CGVirtualDisplayBridge.getSpaceForDisplay(displayID)
            if spaceID != 0 { return spaceID }
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func destroyAttemptDisplay(
        _ displayContext: CGVirtualDisplayBridge.VirtualDisplayContext,
        removalWaitMs: Int = 1500
    )
    async {
        let displayID = displayContext.displayID
        let invalidateSelector = NSSelectorFromString("invalidate")
        let displayObject = displayContext.display

        await MainActor.run {
            VirtualDisplayKeepaliveController.shared.stop(displayID: displayID)
        }

        if (displayObject as AnyObject).responds(to: invalidateSelector) {
            _ = (displayObject as AnyObject).perform(invalidateSelector)
            MirageLogger.host("Invalidated failed-attempt virtual display object \(displayID)")
        }

        CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayID)
        await waitForDisplayRemoval(displayID: displayID, timeoutMs: removalWaitMs)

        if CGVirtualDisplayBridge.isDisplayOnline(displayID) {
            orphanedDisplayIDs.insert(displayID)
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(for: displayContext.colorSpace)
            CGVirtualDisplayBridge.invalidatePersistentSerial(for: displayContext.colorSpace)
            MirageLogger.debug(
                .host,
                "WARNING: Failed-attempt virtual display \(displayID) remained online after invalidation; marked orphaned and rotated descriptor profile/serial"
            )
            return
        }

        orphanedDisplayIDs.remove(displayID)
        MirageLogger.host("Failed-attempt virtual display \(displayID) successfully destroyed")
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
        let success = CGVirtualDisplayBridge.updateDisplayResolution(
            display: display.displayRef.value,
            width: Int(newResolution.width),
            height: Int(newResolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: useHiDPI,
            colorSpace: display.colorSpace,
            isFallbackProbe: true
        )
        guard success else { return nil }

        let updatedScaleFactor = resolvedScaleFactor(displayID: display.displayID, fallback: display.scaleFactor)
        let updatedDisplay = ManagedDisplayContext(
            displayID: display.displayID,
            spaceID: display.spaceID,
            resolution: newResolution,
            scaleFactor: updatedScaleFactor,
            refreshRate: Double(refreshRate),
            colorSpace: display.colorSpace,
            displayP3CoverageStatus: display.displayP3CoverageStatus,
            generation: display.generation,
            createdAt: display.createdAt,
            displayRef: display.displayRef
        )

        await MainActor.run {
            VirtualDisplayKeepaliveController.shared.update(displayID: display.displayID)
        }

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
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor
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
        let dedupedAttempts = creationAttempts(
            resolution: normalizedRequested,
            colorSpace: colorSpace,
            policy: creationPolicy
        )

        for attempt in dedupedAttempts {
            let requestedResolution = attempt.resolution

            guard let displayContext = CGVirtualDisplayBridge.createVirtualDisplay(
                name: displayName,
                width: Int(requestedResolution.width),
                height: Int(requestedResolution.height),
                refreshRate: Double(refreshRate),
                hiDPI: attempt.hiDPI,
                colorSpace: attempt.colorSpace
            ) else {
                MirageLogger.host(
                    "Virtual display create failed for \(attempt.label) at \(Int(requestedResolution.width))x\(Int(requestedResolution.height)), color=\(attempt.colorSpace.displayName)"
                )
                continue
            }

            let modeSizesAtCreate = CGVirtualDisplayBridge.currentDisplayModeSizes(displayContext.displayID)
            let effectiveScaleHint: CGFloat = if let modeSizesAtCreate,
                                                 modeSizesAtCreate.logical.width > 0 {
                max(1.0, modeSizesAtCreate.pixel.width / modeSizesAtCreate.logical.width)
            } else {
                attempt.hiDPI ? 2.0 : 1.0
            }
            let effectivePixel = modeSizesAtCreate?.pixel ?? requestedResolution
            let effectiveLogical = SharedVirtualDisplayManager.logicalResolution(
                for: effectivePixel,
                scaleFactor: effectiveScaleHint
            )

            guard await CGVirtualDisplayBridge.waitForDisplayReady(
                displayContext.displayID,
                expectedResolution: effectiveLogical,
                alternateExpectedResolution: effectivePixel
            ) != nil else {
                await destroyAttemptDisplay(displayContext)
                continue
            }

            let enforceHiDPI = effectiveScaleHint > 1.5
            let enforced = CGVirtualDisplayBridge.updateDisplayResolution(
                display: displayContext.display,
                width: Int(effectivePixel.width.rounded()),
                height: Int(effectivePixel.height.rounded()),
                refreshRate: Double(refreshRate),
                hiDPI: enforceHiDPI,
                colorSpace: attempt.colorSpace,
                isFallbackProbe: true
            )
            guard enforced else {
                await destroyAttemptDisplay(displayContext)
                continue
            }

            guard let spaceID = await waitForSpaceAssignment(displayID: displayContext.displayID) else {
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
                expectedPixelResolution: validatedPixelResolution
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
            let managedContext = ManagedDisplayContext(
                displayID: displayContext.displayID,
                spaceID: spaceID,
                resolution: validatedPixelResolution,
                scaleFactor: displayScaleFactor,
                refreshRate: displayContext.refreshRate,
                colorSpace: displayContext.colorSpace,
                displayP3CoverageStatus: displayContext.displayP3CoverageStatus,
                generation: generation,
                createdAt: Date(),
                displayRef: UncheckedSendableBox(displayContext.display)
            )
            if !attempt.hiDPI {
                MirageLogger.host(
                    "Created shared virtual display using non-Retina fallback at \(Int(validatedPixelResolution.width))x\(Int(validatedPixelResolution.height)) px, color=\(attempt.colorSpace.displayName)"
                )
            }

            if attempt.colorSpace != colorSpace {
                if colorSpace == .displayP3, attempt.colorSpace == .sRGB {
                    MirageLogger.host(
                        "Virtual display color fallback engaged: requested Display P3, effectiveColor=sRGB, coverage=\(managedContext.displayP3CoverageStatus.rawValue)"
                    )
                } else {
                    MirageLogger.host(
                        "Virtual display color fallback engaged: requested \(colorSpace.displayName), using \(attempt.colorSpace.displayName)"
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

            await MainActor.run {
                VirtualDisplayKeepaliveController.shared.start(
                    displayID: displayContext.displayID,
                    spaceID: spaceID,
                    refreshRate: displayContext.refreshRate
                )
            }

            return managedContext
        }

        if case let .screenCaptureKitVisibilityDelayed(displayID) = lastValidationOutcome {
            throw SharedDisplayError.screenCaptureKitVisibilityDelayed(displayID)
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
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor
    )
    async throws -> ManagedDisplayContext {
        await destroyDisplay(removalWaitMs: preferFastRecreate ? 250 : 1500)
        try await Task.sleep(for: .milliseconds(50))
        return try await createDisplay(
            resolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace,
            creationPolicy: creationPolicy
        )
    }

    /// Recreate a specific display instance (used by dedicated stream displays).
    func recreateDisplay(
        from display: ManagedDisplayContext,
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        displayNameOverride: String? = nil,
        preferFastRecreate: Bool = false,
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor
    )
    async throws -> ManagedDisplayContext {
        await destroyDisplay(display, removalWaitMs: preferFastRecreate ? 250 : 1500)
        try await Task.sleep(for: .milliseconds(50))
        return try await createDisplay(
            resolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace,
            displayNameOverride: displayNameOverride,
            creationPolicy: creationPolicy
        )
    }

    func destroyDisplay(_ display: ManagedDisplayContext, removalWaitMs: Int = 3000) async {
        let displayID = display.displayID
        MirageLogger.host("Destroying virtual display, displayID=\(displayID)")

        await MainActor.run {
            VirtualDisplayKeepaliveController.shared.stop(displayID: displayID)
        }

        let invalidateSelector = NSSelectorFromString("invalidate")
        let displayObject = display.displayRef.value
        if (displayObject as AnyObject).responds(to: invalidateSelector) {
            _ = (displayObject as AnyObject).perform(invalidateSelector)
            MirageLogger.host("Invalidated virtual display object \(displayID)")
        }

        CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayID)
        await waitForDisplayRemoval(displayID: displayID, timeoutMs: removalWaitMs)

        if CGVirtualDisplayBridge.isDisplayOnline(displayID) {
            orphanedDisplayIDs.insert(displayID)
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(for: display.colorSpace)
            CGVirtualDisplayBridge.invalidatePersistentSerial(for: display.colorSpace)
            MirageLogger.debug(
                .host,
                "WARNING: Virtual display \(displayID) still online after invalidation; marked orphaned and rotated descriptor profile/serial"
            )
            return
        }

        orphanedDisplayIDs.remove(displayID)
        MirageLogger.host("Virtual display \(displayID) successfully destroyed")
    }

    /// Destroy the shared display
    func destroyDisplay() async {
        await destroyDisplay(removalWaitMs: 1500)
    }

    /// Destroy the shared display with a custom removal wait budget.
    func destroyDisplay(removalWaitMs: Int) async {
        guard let display = sharedDisplay else { return }
        sharedDisplay = nil
        await destroyDisplay(display, removalWaitMs: removalWaitMs)
    }
}
#endif
