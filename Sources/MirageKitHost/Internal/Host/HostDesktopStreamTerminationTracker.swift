//
//  HostDesktopStreamTerminationTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Persists desktop stream run markers to detect unexpected host termination.
//

import Foundation
import MirageKit

#if os(macOS)
actor HostDesktopStreamTerminationTracker {
    static let shared = HostDesktopStreamTerminationTracker()

    private struct ActiveDesktopStreamMarker: Codable {
        let runID: String
        let streamID: StreamID
        let startedAtUnix: TimeInterval
        let requestedPixelWidth: Int
        let requestedPixelHeight: Int
    }

    private static let markerDefaultsKey = "com.mirage.host.desktopStream.activeRun.v1"
    private let runID = UUID().uuidString
    private let defaults = UserDefaults.standard

    func reportUncleanTerminationIfNeeded() {
        guard let data = defaults.data(forKey: Self.markerDefaultsKey) else { return }
        defer { defaults.removeObject(forKey: Self.markerDefaultsKey) }

        let decoder = JSONDecoder()
        guard let marker = try? decoder.decode(ActiveDesktopStreamMarker.self, from: data) else {
            MirageLogger.error(.host, "Desktop stream termination marker decode failed")
            return
        }

        guard marker.runID != runID else { return }

        let ageSeconds = max(0, Int(Date().timeIntervalSince1970 - marker.startedAtUnix))
        MirageLogger.fault(
            .host,
            "Detected unexpected host termination during desktop stream: " +
                "previousRunID=\(marker.runID), streamID=\(marker.streamID), " +
                "requested=\(marker.requestedPixelWidth)x\(marker.requestedPixelHeight) px, " +
                "ageSeconds=\(ageSeconds)"
        )
    }

    func markDesktopStreamStarted(streamID: StreamID, requestedPixelResolution: CGSize) {
        let marker = ActiveDesktopStreamMarker(
            runID: runID,
            streamID: streamID,
            startedAtUnix: Date().timeIntervalSince1970,
            requestedPixelWidth: max(1, Int(requestedPixelResolution.width.rounded())),
            requestedPixelHeight: max(1, Int(requestedPixelResolution.height.rounded()))
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(marker) else {
            MirageLogger.error(.host, "Desktop stream termination marker encode failed")
            return
        }
        defaults.set(data, forKey: Self.markerDefaultsKey)
    }

    func clearDesktopStreamMarker() {
        defaults.removeObject(forKey: Self.markerDefaultsKey)
    }
}
#endif
