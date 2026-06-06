//
//  MirageHostVirtualDisplayBackendValues.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
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
#if os(macOS)
import CoreGraphics
import Foundation

/// Snapshot of a host virtual display expressed independently from the current manager implementation.
struct MirageHostVirtualDisplaySnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let spaceID: CGSSpaceID
    let resolution: CGSize
    let scaleFactor: CGFloat
    let refreshRate: Double
    let colorSpace: MirageMedia.MirageColorSpace
    let displayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus
    let generation: UInt64
    let createdAt: Date

    init(
        displayID: CGDirectDisplayID,
        spaceID: CGSSpaceID,
        resolution: CGSize,
        scaleFactor: CGFloat,
        refreshRate: Double,
        colorSpace: MirageMedia.MirageColorSpace,
        displayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus,
        generation: UInt64,
        createdAt: Date
    ) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.resolution = resolution
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
        self.colorSpace = colorSpace
        self.displayP3CoverageStatus = displayP3CoverageStatus
        self.generation = generation
        self.createdAt = createdAt
    }
}

extension MirageHostVirtualDisplaySnapshot {
    init(snapshot: SharedVirtualDisplayManager.DisplaySnapshot) {
        self.init(
            displayID: snapshot.displayID,
            spaceID: snapshot.spaceID,
            resolution: snapshot.resolution,
            scaleFactor: snapshot.scaleFactor,
            refreshRate: snapshot.refreshRate,
            colorSpace: snapshot.colorSpace,
            displayP3CoverageStatus: snapshot.displayP3CoverageStatus,
            generation: snapshot.generation,
            createdAt: snapshot.createdAt
        )
    }
}

/// Host runtime consumer for a shared virtual display.
enum MirageHostVirtualDisplayConsumer: Hashable, Sendable {
    case desktopStream
    case appStream
    case benchmark
}

/// Policy used when creating a host virtual display.
enum MirageHostVirtualDisplayCreationPolicy: Equatable, Sendable {
    case adaptiveRetinaThenFallback1xAndColor
    case singleAttempt(hiDPI: Bool)
}

/// Capture display resolved by the host virtual-display backend.
struct MirageHostCaptureDisplay: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let pixelSize: CGSize

    init(displayID: CGDirectDisplayID, pixelSize: CGSize) {
        self.displayID = displayID
        self.pixelSize = pixelSize
    }
}

/// Host virtual-display resize request expressed independently from desktop resize-cache helpers.
struct MirageHostVirtualDisplayResizeRequest: Equatable, Sendable {
    let requestedPixelWidth: Int
    let requestedPixelHeight: Int
    let requestedRefreshRate: Int
    let requestedColorSpace: MirageMedia.MirageColorSpace
    let requestedHiDPI: Bool

    init(
        requestedPixelWidth: Int,
        requestedPixelHeight: Int,
        requestedRefreshRate: Int,
        requestedColorSpace: MirageMedia.MirageColorSpace,
        requestedHiDPI: Bool
    ) {
        self.requestedPixelWidth = requestedPixelWidth
        self.requestedPixelHeight = requestedPixelHeight
        self.requestedRefreshRate = requestedRefreshRate
        self.requestedColorSpace = requestedColorSpace
        self.requestedHiDPI = requestedHiDPI
    }
}

extension MirageHostVirtualDisplayResizeRequest {
    init(resizeRequest: DesktopVirtualDisplayResizeRequest) {
        self.init(
            requestedPixelWidth: resizeRequest.requestedPixelWidth,
            requestedPixelHeight: resizeRequest.requestedPixelHeight,
            requestedRefreshRate: resizeRequest.requestedRefreshRate,
            requestedColorSpace: resizeRequest.requestedColorSpace,
            requestedHiDPI: resizeRequest.requestedHiDPI
        )
    }
}

extension DesktopVirtualDisplayResizeRequest {
    init(resizeRequest: MirageHostVirtualDisplayResizeRequest) {
        self.init(
            requestedPixelWidth: resizeRequest.requestedPixelWidth,
            requestedPixelHeight: resizeRequest.requestedPixelHeight,
            requestedRefreshRate: resizeRequest.requestedRefreshRate,
            requestedColorSpace: resizeRequest.requestedColorSpace,
            requestedHiDPI: resizeRequest.requestedHiDPI
        )
    }
}

/// Current logical and physical mode sizes for a host display.
struct MirageHostDisplayModeSizes: Equatable, Sendable {
    let logical: CGSize
    let pixel: CGSize

    init(logical: CGSize, pixel: CGSize) {
        self.logical = logical
        self.pixel = pixel
    }
}

/// Host display color-space validation result expressed without bridge implementation types.
struct MirageHostDisplayColorSpaceValidationResult: Equatable, Sendable {
    let coverageStatus: MirageMedia.MirageDisplayP3CoverageStatus
    let observedName: String?

    init(coverageStatus: MirageMedia.MirageDisplayP3CoverageStatus, observedName: String?) {
        self.coverageStatus = coverageStatus
        self.observedName = observedName
    }

    var isAcceptableForDisplayP3: Bool {
        coverageStatus == .strictCanonical || coverageStatus == .wideGamutEquivalent
    }
}

/// Outcome from a host virtual-display resolution update.
enum MirageHostDisplayResolutionUpdateOutcome: Equatable, Sendable {
    case noChange
    case updatedInPlace
    case requiresRecreation
    case recreated
}

/// Result from updating a host virtual display's resolution.
struct MirageHostDisplayResolutionUpdateResult: Equatable, Sendable {
    let outcome: MirageHostDisplayResolutionUpdateOutcome
    let generationChanged: Bool

    init(outcome: MirageHostDisplayResolutionUpdateOutcome, generationChanged: Bool) {
        self.outcome = outcome
        self.generationChanged = generationChanged
    }
}

/// Result of probing whether a virtual display is presenting at the requested cadence.
struct MirageHostVirtualDisplayCadenceValidation: Equatable, Sendable {
    let targetFPS: Double
    let observedFPS: Double?
    let usesNativeDisplayCadence: Bool

    init(targetFPS: Double, observedFPS: Double?, usesNativeDisplayCadence: Bool) {
        self.targetFPS = targetFPS
        self.observedFPS = observedFPS
        self.usesNativeDisplayCadence = usesNativeDisplayCadence
    }

    var logLabel: String {
        let observedText = observedFPS
            .map { $0.formatted(.number.precision(.fractionLength(1))) }
            ?? "unavailable"
        return "target=\(Int(targetFPS))Hz observed=\(observedText)Hz nativeCadence=\(usesNativeDisplayCadence)"
    }
}
#endif
