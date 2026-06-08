//
//  StreamContextMosaicLiveSmokeTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/8/26.
//

#if os(macOS)
@testable import MirageKitHost
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Live Smoke")
struct StreamContextMosaicLiveSmokeTests {
    @Test("Live smoke writes current host Mosaic plan")
    func liveSmokeWritesCurrentHostMosaicPlan() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["MIRAGE_MOSAIC_LIVE_SMOKE_OUT"],
              !outputPath.isEmpty else {
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let screenshotURL = outputURL.appendingPathComponent("screenshot.png")
        let logicalSize = try Self.logicalSize(fromScreenshotAt: screenshotURL)
        let displayID = CGMainDisplayID()
        let captureBounds = CGDisplayBounds(displayID)
        let observations = MacOSMosaicSemanticObservationProvider().observations()
        let snapshot = StreamContextMosaicSemanticSnapshotBuilder().snapshot(
            logicalSize: logicalSize,
            captureBounds: captureBounds,
            windows: observations
        )

        var tracker = StreamContextMosaicDirtyTileTracker()
        let frame = StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 1,
            semanticCandidates: snapshot.candidates,
            isTransientSystemState: snapshot.isTransientSystemState
        )
        guard let result = tracker.record(frame) else {
            throw LiveSmokeError.planUnavailable
        }

        try Self.writePlanJSON(
            observations: observations,
            snapshot: snapshot,
            plan: result.plan,
            captureBounds: captureBounds,
            accessibilityTrusted: AXIsProcessTrusted(),
            to: outputURL.appendingPathComponent("plan.json")
        )

        #expect(!observations.isEmpty)
        #expect(!result.plan.tiles.isEmpty)
    }

    private static func logicalSize(fromScreenshotAt url: URL) throws -> MiragePixelSize {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = intValue(properties[kCGImagePropertyPixelWidth]),
              let height = intValue(properties[kCGImagePropertyPixelHeight]) else {
            throw LiveSmokeError.screenshotUnavailable
        }
        return MiragePixelSize(width: width, height: height)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func writePlanJSON(
        observations: [StreamContextMosaicSemanticWindowObservation],
        snapshot: StreamContextMosaicSemanticSnapshot,
        plan: MirageMosaicTilePlan,
        captureBounds: CGRect,
        accessibilityTrusted: Bool,
        to url: URL
    ) throws {
        let payload: [String: Any] = [
            "logicalSize": sizeJSON(plan.logicalSize),
            "captureBounds": rectJSON(captureBounds),
            "accessibilityTrusted": accessibilityTrusted,
            "windowObservationCount": observations.count,
            "semanticCandidateCount": snapshot.candidates.count,
            "isTransientSystemState": snapshot.isTransientSystemState,
            "planKind": plan.kind.rawValue,
            "planEpoch": Int(plan.epoch),
            "tileCount": plan.tiles.count,
            "codecUnitCount": plan.codecUnits.count,
            "windows": observations.map(windowJSON(_:)),
            "candidates": snapshot.candidates.map(candidateJSON(_:)),
            "tiles": plan.tiles.map(tileJSON(_:)),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func tileJSON(_ tile: MirageMosaicTileDescriptor) -> [String: Any] {
        var payload: [String: Any] = [
            "id": tile.id.rawValue,
            "sourceRect": pixelRectJSON(tile.sourceRect),
            "presentationRect": pixelRectJSON(tile.presentationRect),
            "semanticClass": tile.semanticClass.rawValue,
            "priority": tile.priority.rawValue,
            "codecStrategy": tile.codecStrategy.rawValue,
            "transportGroupID": tile.transportGroupID.rawValue,
            "presentationGroupID": tile.presentationGroupID.rawValue,
            "commitPolicy": tile.commitPolicy.rawValue,
            "textSensitive": tile.textSensitive,
        ]
        if let parentTileID = tile.parentTileID {
            payload["parentTileID"] = parentTileID.rawValue
        }
        if let subtileIndex = tile.subtileIndex {
            payload["subtileIndex"] = subtileIndex
        }
        return payload
    }

    private static func windowJSON(_ window: StreamContextMosaicSemanticWindowObservation) -> [String: Any] {
        var payload: [String: Any] = [
            "windowID": UInt32(window.windowID),
            "ownerName": window.ownerName ?? "",
            "frame": rectJSON(window.frame),
            "layer": window.layer,
            "alpha": Double(window.alpha),
            "isOnScreen": window.isOnScreen,
            "orderIndex": window.orderIndex,
            "role": window.role ?? "",
            "subrole": window.subrole ?? "",
            "isFocused": window.isFocused,
            "isMain": window.isMain,
            "isModal": window.isModal,
            "childCount": window.children.count,
            "children": window.children.prefix(48).map(elementJSON(_:)),
        ]
        if let ownerProcessID = window.ownerProcessID {
            payload["ownerProcessID"] = Int(ownerProcessID)
        }
        return payload
    }

    private static func elementJSON(_ element: StreamContextMosaicSemanticElementObservation) -> [String: Any] {
        [
            "id": element.id,
            "role": element.role,
            "frame": rectJSON(element.frame),
            "subrole": element.subrole ?? "",
            "depth": element.depth,
            "isFocused": element.isFocused,
        ]
    }

    private static func candidateJSON(_ candidate: StreamContextMosaicSemanticCandidate) -> [String: Any] {
        var payload: [String: Any] = [
            "id": candidate.id.rawValue,
            "rect": pixelRectJSON(candidate.rect),
            "semanticClass": candidate.semanticClass.rawValue,
            "priority": candidate.priority.rawValue,
            "codecStrategy": candidate.codecStrategy.rawValue,
            "commitPolicy": candidate.commitPolicy.rawValue,
            "isReliable": candidate.isReliable,
        ]
        if let parentID = candidate.parentID {
            payload["parentID"] = parentID.rawValue
        }
        return payload
    }

    private static func sizeJSON(_ size: MiragePixelSize) -> [String: Int] {
        [
            "width": size.width,
            "height": size.height,
        ]
    }

    private static func pixelRectJSON(_ rect: MiragePixelRect) -> [String: Int] {
        [
            "x": rect.x,
            "y": rect.y,
            "width": rect.width,
            "height": rect.height,
        ]
    }

    private static func rectJSON(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.width,
            "height": rect.height,
        ]
    }
}

private enum LiveSmokeError: Error {
    case screenshotUnavailable
    case planUnavailable
}
#endif
