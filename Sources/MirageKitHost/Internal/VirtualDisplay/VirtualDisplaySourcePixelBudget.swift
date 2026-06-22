//
//  VirtualDisplaySourcePixelBudget.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/18/26.
//

import CoreGraphics
import Foundation
import MirageMedia

#if os(macOS)

struct VirtualDisplaySourcePixelBudget: Sendable, Equatable {
    struct DisplayLoad: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let sourcePixels: CGFloat
    }

    static let conservativeTotalSourcePixels: CGFloat = 30_965_760
    static let safetyMarginPixels: CGFloat = 1_000_000

    let totalSourcePixels: CGFloat
    let safetyMarginPixels: CGFloat
    let displayLoads: [DisplayLoad]

    var currentSourcePixels: CGFloat {
        displayLoads.reduce(CGFloat.zero) { $0 + $1.sourcePixels }
    }

    var availableSourcePixels: CGFloat {
        max(0, totalSourcePixels - currentSourcePixels - safetyMarginPixels)
    }

    var summary: String {
        let loadText = displayLoads
            .map { "\($0.displayID)=\(Int($0.sourcePixels.rounded()))" }
            .joined(separator: ",")
        return "current=\(Int(currentSourcePixels.rounded())) available=\(Int(availableSourcePixels.rounded())) total=\(Int(totalSourcePixels.rounded())) margin=\(Int(safetyMarginPixels.rounded())) loads=[\(loadText)]"
    }

    static func isRequiredForVirtualDisplayStartup(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        osVersion.majorVersion == 27
    }

    static func current() -> VirtualDisplaySourcePixelBudget? {
        guard isRequiredForVirtualDisplayStartup() else { return nil }

        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }

        let displayLoads = displays
            .prefix(Int(displayCount))
            .filter { $0 != 0 && !CGVirtualDisplayBridge.isMirageDisplay($0) }
            .map { displayID in
                DisplayLoad(
                    displayID: displayID,
                    sourcePixels: estimatedSourcePixels(for: displayID)
                )
            }
            .filter { $0.sourcePixels > 0 }

        guard !displayLoads.isEmpty else { return nil }
        return VirtualDisplaySourcePixelBudget(
            totalSourcePixels: conservativeTotalSourcePixels,
            safetyMarginPixels: safetyMarginPixels,
            displayLoads: displayLoads
        )
    }

    static func pixelArea(_ size: CGSize) -> CGFloat {
        max(0, size.width) * max(0, size.height)
    }

    static func estimatedSourcePixels(for displayID: CGDirectDisplayID) -> CGFloat {
        var candidates: [CGFloat] = []

        if let mode = CGDisplayCopyDisplayMode(displayID) {
            candidates.append(CGFloat(mode.pixelWidth) * CGFloat(mode.pixelHeight))
            candidates.append(CGFloat(mode.width) * CGFloat(mode.height) * 4)
        }

        let bounds = CGDisplayBounds(displayID)
        if bounds.width > 0, bounds.height > 0 {
            candidates.append(bounds.width * bounds.height * 4)
        }

        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        if pixelWidth > 0, pixelHeight > 0 {
            candidates.append(CGFloat(pixelWidth) * CGFloat(pixelHeight))
        }

        return candidates.max() ?? 0
    }

    static func cappedResolutionPreservingAspect(
        _ resolution: CGSize,
        maxPixelArea: CGFloat,
        minimumSize: CGSize
    ) -> CGSize? {
        let sourceArea = pixelArea(resolution)
        guard sourceArea > 0, maxPixelArea > 0, maxPixelArea < sourceArea else {
            return sourceArea <= maxPixelArea ? resolution : nil
        }

        let scale = sqrt(maxPixelArea / sourceArea)
        var candidate = CGSize(
            width: CGFloat(MirageStreamGeometry.alignedEncodedDimension(resolution.width * scale)),
            height: CGFloat(MirageStreamGeometry.alignedEncodedDimension(resolution.height * scale))
        )

        while pixelArea(candidate) > maxPixelArea, candidate.width > minimumSize.width, candidate.height > minimumSize.height {
            if candidate.width >= candidate.height {
                candidate.width = max(minimumSize.width, candidate.width - 16)
            } else {
                candidate.height = max(minimumSize.height, candidate.height - 16)
            }
        }

        guard pixelArea(candidate) <= maxPixelArea,
              candidate.width >= minimumSize.width,
              candidate.height >= minimumSize.height else {
            return nil
        }

        return candidate
    }
}

extension SharedVirtualDisplayManager {
    static let minimumResourceBudgetedRetinaResolution = CGSize(width: 2048, height: 1536)

    static func resourceBudgetedCreationAttempt(
        _ attempt: DisplayCreationAttempt,
        budget: VirtualDisplaySourcePixelBudget? = VirtualDisplaySourcePixelBudget.current()
    ) -> DisplayCreationAttempt {
        guard attempt.hiDPI, let budget else { return attempt }

        let requestedPixels = VirtualDisplaySourcePixelBudget.pixelArea(attempt.resolution)
        let availablePixels = budget.availableSourcePixels
        guard requestedPixels > availablePixels else { return attempt }

        if let cappedRetinaResolution = VirtualDisplaySourcePixelBudget.cappedResolutionPreservingAspect(
            attempt.resolution,
            maxPixelArea: availablePixels,
            minimumSize: minimumResourceBudgetedRetinaResolution
        ) {
            return DisplayCreationAttempt(
                resolution: cappedRetinaResolution,
                hiDPI: true,
                colorSpace: attempt.colorSpace,
                label: "resource-budgeted-retina-\(attempt.label)"
            )
        }

        return DisplayCreationAttempt(
            resolution: fallbackResolution(for: attempt.resolution),
            hiDPI: false,
            colorSpace: attempt.colorSpace,
            label: "resource-budgeted-1x-\(attempt.label)"
        )
    }
}

#endif
