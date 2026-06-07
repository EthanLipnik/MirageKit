//
//  CGVirtualDisplayBridge+ColorValidation.swift
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
#if os(macOS)
import CoreGraphics
import Foundation

extension CGVirtualDisplayBridge {
    struct DisplayColorSpaceValidationResult: Sendable {
        let coverageStatus: MirageMedia.MirageDisplayP3CoverageStatus
        let observedName: String?

        var isAcceptableForDisplayP3: Bool {
            coverageStatus == .strictCanonical || coverageStatus == .wideGamutEquivalent
        }
    }

    static func displayColorSpaceValidation(
        observedColorSpace: CGColorSpace,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> DisplayColorSpaceValidationResult {
        let observedName = observedColorSpace.name.map { $0 as String }
        let expectedNames = expectedColorSpaceNames(for: expectedColorSpace)
        let expectedColorSpaces = expectedColorSpaces(for: expectedColorSpace)
        let sRGBNames = expectedColorSpaceNames(for: .sRGB)
        guard !expectedColorSpaces.isEmpty else {
            return DisplayColorSpaceValidationResult(
                coverageStatus: .unresolved,
                observedName: observedName
            )
        }

        if let observedName, expectedNames.contains(observedName) {
            return DisplayColorSpaceValidationResult(
                coverageStatus: expectedColorSpace == .displayP3 ? .strictCanonical : .sRGBFallback,
                observedName: observedName
            )
        }

        if expectedColorSpaces.contains(where: { CFEqual(observedColorSpace, $0) }) {
            return DisplayColorSpaceValidationResult(
                coverageStatus: expectedColorSpace == .displayP3 ? .strictCanonical : .sRGBFallback,
                observedName: observedName ?? "strict-equivalent"
            )
        }

        if let observedICCData = observedColorSpace.copyICCData() as Data?,
           expectedColorSpaces.compactMap({ $0.copyICCData() as Data? }).contains(observedICCData) {
            return DisplayColorSpaceValidationResult(
                coverageStatus: expectedColorSpace == .displayP3 ? .strictCanonical : .sRGBFallback,
                observedName: observedName ?? "icc-match"
            )
        }

        if let observedPropertyListData = propertyListData(observedColorSpace.copyPropertyList()) {
            let expectedPropertyListData = expectedColorSpaces.compactMap { colorSpace in
                propertyListData(colorSpace.copyPropertyList())
            }
            if expectedPropertyListData.contains(observedPropertyListData) {
                return DisplayColorSpaceValidationResult(
                    coverageStatus: expectedColorSpace == .displayP3 ? .strictCanonical : .sRGBFallback,
                    observedName: observedName ?? "property-list-match"
                )
            }
        }

        switch expectedColorSpace {
        case .displayP3:
            if let observedName, sRGBNames.contains(observedName) {
                return DisplayColorSpaceValidationResult(
                    coverageStatus: .sRGBFallback,
                    observedName: observedName
                )
            }

            if observedColorSpace.model == .rgb {
                let observedWideGamut = observedColorSpace.isWideGamutRGB
                if observedName == nil {
                    return DisplayColorSpaceValidationResult(
                        coverageStatus: .wideGamutEquivalent,
                        observedName: observedWideGamut ? "wide-gamut-rgb" : "unnamed-rgb"
                    )
                }
                if observedWideGamut {
                    return DisplayColorSpaceValidationResult(
                        coverageStatus: .unresolved,
                        observedName: observedName
                    )
                }
                return DisplayColorSpaceValidationResult(
                    coverageStatus: .sRGBFallback,
                    observedName: observedName ?? "standard-gamut-rgb"
                )
            }

            return DisplayColorSpaceValidationResult(
                coverageStatus: .unresolved,
                observedName: observedName ?? "unknown"
            )

        case .sRGB:
            if observedColorSpace.model == .rgb, !observedColorSpace.isWideGamutRGB {
                return DisplayColorSpaceValidationResult(
                    coverageStatus: .sRGBFallback,
                    observedName: observedName ?? "standard-gamut-rgb"
                )
            }
            return DisplayColorSpaceValidationResult(
                coverageStatus: .unresolved,
                observedName: observedName ?? "unknown"
            )
        }
    }

    static func displayColorSpaceValidation(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> DisplayColorSpaceValidationResult {
        let observedColorSpace = CGDisplayCopyColorSpace(displayID)
        return displayColorSpaceValidation(
            observedColorSpace: observedColorSpace,
            expectedColorSpace: expectedColorSpace
        )
    }

    private static func expectedColorSpaceNames(for colorSpace: MirageMedia.MirageColorSpace) -> Set<String> {
        switch colorSpace {
        case .displayP3:
            return [
                CGColorSpace.displayP3 as String,
                CGColorSpace.extendedDisplayP3 as String,
            ]
        case .sRGB:
            return [
                CGColorSpace.sRGB as String,
                CGColorSpace.extendedSRGB as String,
                CGColorSpace.linearSRGB as String,
            ]
        }
    }

    private static func expectedColorSpaces(for colorSpace: MirageMedia.MirageColorSpace) -> [CGColorSpace] {
        expectedColorSpaceNames(for: colorSpace).compactMap { name in
            CGColorSpace(name: name as CFString)
        }
    }

    private static func propertyListData(_ propertyList: CFPropertyList?) -> Data? {
        guard let propertyList else { return nil }
        guard let data = CFPropertyListCreateData(
            kCFAllocatorDefault,
            propertyList,
            .binaryFormat_v1_0,
            0,
            nil
        ) else {
            return nil
        }
        return data.takeRetainedValue() as Data
    }
}
#endif
