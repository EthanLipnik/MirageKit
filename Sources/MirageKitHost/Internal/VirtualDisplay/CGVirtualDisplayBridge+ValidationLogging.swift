//
//  CGVirtualDisplayBridge+ValidationLogging.swift
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
import CoreGraphics
import Foundation

#if os(macOS)

extension CGVirtualDisplayBridge {
    static func logVirtualDisplaySettingsProbeFailure(
        attemptLabel: String,
        transferFunctionLabel: String
    ) {
        MirageLogger.host(
            "Virtual display settings probe failed for attempt \(attemptLabel) with transferFunction=\(transferFunctionLabel); trying next transfer function"
        )
    }

    static func logVirtualDisplayCreationProbeFailure(profileLabel: String) {
        MirageLogger.host(
            "CGVirtualDisplay initialization failed for profile \(profileLabel); trying next descriptor profile"
        )
    }

    static func logVirtualDisplayResolutionUpdateFailure(
        hiDPI: Bool,
        isTerminal: Bool
    ) {
        let modeLabel = hiDPI ? "Retina" : "1x"
        let message = isTerminal
            ? "Updated virtual display failed \(modeLabel) activation"
            : "Virtual display resolution update probe failed \(modeLabel) activation; trying next display candidate"

        if isTerminal {
            MirageLogger.error(.host, message)
        } else {
            MirageLogger.host(message)
        }
    }

    static func validatedDisplayColorSpace(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> DisplayColorSpaceValidationResult {
        var latest = DisplayColorSpaceValidationResult(
            coverageStatus: .unresolved,
            observedName: nil
        )
        for attempt in 0 ..< colorValidationAttempts {
            latest = displayColorSpaceValidation(
                displayID: displayID,
                expectedColorSpace: expectedColorSpace
            )
            switch expectedColorSpace {
            case .displayP3:
                if latest.isAcceptableForDisplayP3 { return latest }
            case .sRGB:
                if latest.coverageStatus == .sRGBFallback { return latest }
            }
            if attempt < colorValidationAttempts - 1 {
                Thread.sleep(forTimeInterval: colorValidationDelaySeconds)
            }
        }
        return latest
    }

    static func acceptValidatedVirtualDisplayColor(
        _ colorValidation: DisplayColorSpaceValidationResult,
        colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool,
        profile: DescriptorAttempt,
        allowDisplayP3SRGBFallback: Bool = false
    ) -> Bool {
        let observedColorName = colorValidation.observedName ?? "unknown"
        let coverageStatus = colorValidation.coverageStatus
        switch coverageStatus {
        case .strictCanonical:
            MirageLogger.host(
                "Virtual display color profile validated (color=\(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
            )
            return true
        case .wideGamutEquivalent:
            if colorSpace == .displayP3 {
                MirageLogger.host(
                    "Virtual display color profile validated (color=Display P3 equivalent-wide-gamut, coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                )
            } else {
                MirageLogger.host(
                    "Virtual display color profile mismatch tolerated for fallback (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                )
            }
            return true
        case .sRGBFallback, .unresolved:
            if colorSpace == .displayP3,
               coverageStatus == .sRGBFallback,
               allowDisplayP3SRGBFallback {
                clearValidationHint(
                    for: colorSpace,
                    width: width,
                    height: height,
                    refreshRate: refreshRate,
                    hiDPI: hiDPI
                )
                MirageLogger.host(
                    "Virtual display color fallback accepted (requested \(colorSpace.displayName), effective=sRGB, coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                )
                return true
            }
            if colorSpace == .displayP3 {
                clearValidationHint(
                    for: colorSpace,
                    width: width,
                    height: height,
                    refreshRate: refreshRate,
                    hiDPI: hiDPI
                )
                MirageLogger.host(
                    "WARNING: Virtual display color profile mismatch (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                )
                return false
            }
            MirageLogger.host(
                "Virtual display color profile mismatch tolerated for fallback (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
            )
            return true
        }
    }
}

#endif
