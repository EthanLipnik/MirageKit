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

    enum DesktopStreamStartupStage: String, Codable, Sendable {
        case displaySetup
        case streamStarted
        case firstPacket
    }

    private struct ActiveDesktopStreamMarker: Codable {
        let runID: String
        let streamID: StreamID
        let startedAtUnix: TimeInterval
        let requestedPixelWidth: Int
        let requestedPixelHeight: Int
        var stage: DesktopStreamStartupStage?
        var firstPacketSentAtUnix: TimeInterval?
    }

    private static let markerDefaultsKey = "com.mirage.host.desktopStream.activeRun.v1"
    private let runID = UUID().uuidString
    private let defaults = UserDefaults.standard

    nonisolated static func shouldTrackTerminationMarkers(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !bundleIdentifier.hasSuffix("-Debug")
    }

    nonisolated static func shouldReportUncleanTermination(
        currentRunID: String,
        markerRunID: String,
        firstPacketSentAtUnix: TimeInterval?,
        stage: DesktopStreamStartupStage? = nil
    ) -> Bool {
        guard markerRunID != currentRunID else { return false }
        if firstPacketSentAtUnix != nil { return true }
        return stage == .displaySetup || stage == .streamStarted
    }

    func reportUncleanTerminationIfNeeded() {
        guard Self.shouldTrackTerminationMarkers(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            defaults.removeObject(forKey: Self.markerDefaultsKey)
            return
        }
        guard let data = defaults.data(forKey: Self.markerDefaultsKey) else { return }
        defer { defaults.removeObject(forKey: Self.markerDefaultsKey) }

        let decoder = JSONDecoder()
        let marker: ActiveDesktopStreamMarker
        do {
            marker = try decoder.decode(ActiveDesktopStreamMarker.self, from: data)
        } catch {
            MirageLogger.error(.host, error: error, message: "Desktop stream termination marker decode failed: ")
            return
        }

        guard Self.shouldReportUncleanTermination(
            currentRunID: runID,
            markerRunID: marker.runID,
            firstPacketSentAtUnix: marker.firstPacketSentAtUnix,
            stage: marker.stage
        ) else {
            return
        }

        CGVirtualDisplayBridge.invalidateAllPersistentSerials()

        let ageSeconds = max(0, Int(Date().timeIntervalSince1970 - marker.startedAtUnix))
        MirageLogger.fault(
            .host,
            "Detected unexpected host termination during desktop stream setup: " +
                "previousRunID=\(marker.runID), streamID=\(marker.streamID), " +
                "stage=\(marker.stage?.rawValue ?? "unknown"), " +
                "requested=\(marker.requestedPixelWidth)x\(marker.requestedPixelHeight) px, " +
                "ageSeconds=\(ageSeconds)"
        )
    }

    func markDesktopDisplaySetupStarted(streamID: StreamID, requestedPixelResolution: CGSize) {
        writeMarker(
            streamID: streamID,
            requestedPixelResolution: requestedPixelResolution,
            stage: .displaySetup,
            firstPacketSentAtUnix: nil
        )
    }

    func markDesktopStreamStarted(streamID: StreamID, requestedPixelResolution: CGSize) {
        writeMarker(
            streamID: streamID,
            requestedPixelResolution: requestedPixelResolution,
            stage: .streamStarted,
            firstPacketSentAtUnix: nil
        )
    }

    private func writeMarker(
        streamID: StreamID,
        requestedPixelResolution: CGSize,
        stage: DesktopStreamStartupStage,
        firstPacketSentAtUnix: TimeInterval?
    ) {
        guard Self.shouldTrackTerminationMarkers(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        let marker = ActiveDesktopStreamMarker(
            runID: runID,
            streamID: streamID,
            startedAtUnix: Date().timeIntervalSince1970,
            requestedPixelWidth: max(1, Int(requestedPixelResolution.width.rounded())),
            requestedPixelHeight: max(1, Int(requestedPixelResolution.height.rounded())),
            stage: stage,
            firstPacketSentAtUnix: firstPacketSentAtUnix
        )

        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(marker)
        } catch {
            MirageLogger.error(.host, error: error, message: "Desktop stream termination marker encode failed: ")
            return
        }
        defaults.set(data, forKey: Self.markerDefaultsKey)
    }

    func markDesktopStreamFirstPacketSent(streamID: StreamID) {
        guard Self.shouldTrackTerminationMarkers(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        guard let data = defaults.data(forKey: Self.markerDefaultsKey) else { return }

        let decoder = JSONDecoder()
        var marker: ActiveDesktopStreamMarker
        do {
            marker = try decoder.decode(ActiveDesktopStreamMarker.self, from: data)
        } catch {
            MirageLogger.error(.host, error: error, message: "Desktop stream termination marker decode failed: ")
            return
        }
        guard marker.runID == runID, marker.streamID == streamID else { return }
        guard marker.firstPacketSentAtUnix == nil else { return }

        marker.stage = .firstPacket
        marker.firstPacketSentAtUnix = Date().timeIntervalSince1970

        let encoder = JSONEncoder()
        let encoded: Data
        do {
            encoded = try encoder.encode(marker)
        } catch {
            MirageLogger.error(.host, error: error, message: "Desktop stream termination marker encode failed: ")
            return
        }
        defaults.set(encoded, forKey: Self.markerDefaultsKey)
    }

    func clearDesktopStreamMarker() {
        defaults.removeObject(forKey: Self.markerDefaultsKey)
    }
}
#endif
