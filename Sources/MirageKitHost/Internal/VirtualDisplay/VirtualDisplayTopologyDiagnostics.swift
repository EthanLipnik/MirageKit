//
//  VirtualDisplayTopologyDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
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
struct VirtualDisplayTopologyDiagnostics: Sendable, Equatable {
    struct Display: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let isMain: Bool
        let isMirageVirtual: Bool
        let isBuiltIn: Bool
        let refreshRate: Double?
        let mirrorsDisplayID: CGDirectDisplayID?
        let mirrorRootDisplayID: CGDirectDisplayID
        let isInMirrorSet: Bool

        var classification: String {
            if isMirageVirtual { return "mirage-virtual" }
            if isBuiltIn { return "built-in-physical" }
            return "external-physical"
        }

        var summary: String {
            let refreshText = refreshRate
                .map { $0.formatted(.number.precision(.fractionLength(1))) }
                ?? "unknown"
            let mirrorsText = mirrorsDisplayID.map(String.init) ?? "none"
            return "id=\(displayID),online=true,kind=\(classification),main=\(isMain)," +
                "refresh=\(refreshText),mirrors=\(mirrorsText),root=\(mirrorRootDisplayID)," +
                "mirrorSet=\(isInMirrorSet)"
        }
    }

    let targetFrameRate: Int
    let virtualDisplayID: CGDirectDisplayID?
    let displays: [Display]
    let cadenceLimitReason: String?

    static func snapshot(
        targetFrameRate: Int,
        virtualDisplayID: CGDirectDisplayID?
    ) -> VirtualDisplayTopologyDiagnostics {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        displayIDs = Array(displayIDs.prefix(Int(displayCount))).filter { $0 != 0 }

        let displays = displayIDs.map { displayID in
            let mirrorsDisplayID = mirroredDisplayID(for: displayID)
            return Display(
                displayID: displayID,
                isMain: displayID == CGMainDisplayID(),
                isMirageVirtual: CGVirtualDisplayBridge.isMirageDisplay(displayID),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                refreshRate: refreshRate(for: displayID),
                mirrorsDisplayID: mirrorsDisplayID,
                mirrorRootDisplayID: mirrorRootDisplayID(for: displayID),
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0 || mirrorsDisplayID != nil
            )
        }
        let reason = cadenceLimitReason(
            targetFrameRate: targetFrameRate,
            virtualDisplayID: virtualDisplayID,
            displays: displays
        )
        return VirtualDisplayTopologyDiagnostics(
            targetFrameRate: max(1, targetFrameRate),
            virtualDisplayID: virtualDisplayID,
            displays: displays,
            cadenceLimitReason: reason
        )
    }

    func log(streamID: StreamID) {
        let reasonText = cadenceLimitReason ?? "none"
        let virtualText = virtualDisplayID.map(String.init) ?? "none"
        let displayText = displays.map(\.summary).joined(separator: ";")
        MirageLogger.capture(
            "event=display_topology_diagnostics stream=\(streamID) target=\(targetFrameRate)fps " +
                "virtualDisplay=\(virtualText) reason=\(reasonText) displays=[\(displayText)]"
        )
    }

    private static func cadenceLimitReason(
        targetFrameRate: Int,
        virtualDisplayID: CGDirectDisplayID?,
        displays: [Display]
    ) -> String? {
        guard let virtualDisplayID,
              targetFrameRate >= 90,
              let virtualDisplay = displays.first(where: { $0.displayID == virtualDisplayID }) else {
            return nil
        }
        let targetFloor = Double(targetFrameRate) * 0.90
        let limitedPhysicalDisplay = displays.first { display in
            guard display.displayID != virtualDisplayID,
                  !display.isMirageVirtual,
                  display.mirrorRootDisplayID == virtualDisplay.mirrorRootDisplayID,
                  display.isInMirrorSet,
                  let refreshRate = display.refreshRate else {
                return false
            }
            return refreshRate > 0 && refreshRate < targetFloor
        }
        guard let limitedPhysicalDisplay else { return nil }
        return limitedPhysicalDisplay.isBuiltIn
            ? "physical-display-cadence-limited"
            : "external-display-cadence-limited"
    }

    private static func refreshRate(for displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let refreshRate = mode.refreshRate
        guard refreshRate > 0 else { return nil }
        return refreshRate
    }

    private static func mirroredDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
        guard mirroredDisplayID != kCGNullDirectDisplay else { return nil }
        return mirroredDisplayID
    }

    private static func mirrorRootDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
        var current = displayID
        var seen: Set<CGDirectDisplayID> = [displayID]
        while let next = mirroredDisplayID(for: current), !seen.contains(next) {
            seen.insert(next)
            current = next
        }
        return current
    }
}
#endif
