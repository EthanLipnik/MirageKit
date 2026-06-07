//
//  StreamContext+BufferPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Capture-to-encode buffer sizing policy.
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
import Foundation

#if os(macOS)
/// Capture-to-encode queue sizing selected for a stream at startup.
struct StreamBufferPolicy: Sendable {
    /// Number of frames the capture inbox can retain before applying backpressure.
    let bufferDepth: Int

    /// Initial target for simultaneous VideoToolbox encodes.
    let initialInFlightFrames: Int

    /// Lower bound used when adaptive in-flight tuning recovers after pressure.
    let minimumInFlightFrames: Int

    /// Hard cap for simultaneous VideoToolbox encodes.
    let maxInFlightFramesCap: Int
}

extension StreamContext {
    /// Resolves the capture inbox and encoder in-flight policy for a stream startup request.
    static func resolvedBufferPolicy(
        streamKind: VideoEncoder.StreamKind,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .freshestFrame,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        useLowLatencyPipeline: Bool
    ) -> StreamBufferPolicy {
        if mediaPathProfile.usesAwdlRadioPolicy {
            return awdlInteractiveDisplayBufferPolicy(
                streamKind: streamKind,
                frameRate: frameRate
            )
        }

        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            return StreamBufferPolicy(
                bufferDepth: 1,
                initialInFlightFrames: 1,
                minimumInFlightFrames: 1,
                maxInFlightFramesCap: 1
            )
        }
        if latencyMode == .balanced, hostBufferingPolicy == .freshestFrame {
            let highRefresh = frameRate >= 90
            let cap = highRefresh ? 3 : 2
            let initialInFlight = highRefresh ? 2 : 1
            return StreamBufferPolicy(
                bufferDepth: cap,
                initialInFlightFrames: initialInFlight,
                minimumInFlightFrames: initialInFlight,
                maxInFlightFramesCap: cap
            )
        }

        let usesDesktopLowLatency60HzBufferPolicy = usesStandardDesktopLowLatency60HzBufferPolicy(
            streamKind: streamKind,
            frameRate: frameRate,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy
        )
        var bufferDepth = frameBufferDepth(
            useLowLatencyPipeline: useLowLatencyPipeline,
            frameRate: frameRate,
            latencyMode: latencyMode
        )
        var minInFlight = minInFlightFrames(
            useLowLatencyPipeline: useLowLatencyPipeline,
            frameRate: frameRate,
            latencyMode: latencyMode
        )
        var inFlightCap = min(
            bufferDepth,
            inFlightCap(
                useLowLatencyPipeline: useLowLatencyPipeline,
                frameRate: frameRate,
                latencyMode: latencyMode
            )
        )

        if usesDesktopLowLatency60HzBufferPolicy {
            bufferDepth = max(bufferDepth, 2)
            minInFlight = max(minInFlight, 2)
            inFlightCap = max(inFlightCap, 2)
        }

        let resolvedInFlightCap = max(1, inFlightCap)
        return StreamBufferPolicy(
            bufferDepth: bufferDepth,
            initialInFlightFrames: min(minInFlight, resolvedInFlightCap),
            minimumInFlightFrames: minInFlight,
            maxInFlightFramesCap: resolvedInFlightCap
        )
    }

    /// Returns the host pipeline depth for AWDL interactive display streams.
    static func awdlInteractiveDisplayBufferPolicy(
        streamKind: VideoEncoder.StreamKind,
        frameRate: Int
    ) -> StreamBufferPolicy {
        let safeFrameRate = max(1, frameRate)
        let isDesktopLike = streamKind == .desktop || streamKind == .appAtlas
        let bufferDepth: Int
        let initialInFlight: Int
        let maximumInFlight: Int
        if safeFrameRate >= 45, isDesktopLike {
            bufferDepth = 3
            initialInFlight = 2
            maximumInFlight = 3
        } else if safeFrameRate >= 45 {
            bufferDepth = 2
            initialInFlight = 1
            maximumInFlight = 2
        } else {
            bufferDepth = 2
            initialInFlight = 1
            maximumInFlight = 2
        }

        return StreamBufferPolicy(
            bufferDepth: bufferDepth,
            initialInFlightFrames: initialInFlight,
            minimumInFlightFrames: initialInFlight,
            maxInFlightFramesCap: maximumInFlight
        )
    }

    /// Returns the frame inbox depth for the stream latency profile.
    static func frameBufferDepth(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return frameRate >= 120 ? 2 : 1 }
        switch latencyMode {
        case .balanced:
            if frameRate >= 90 { return 3 }
            return 2
        case .smoothest:
            if frameRate >= 120 { return 12 }
            if frameRate >= 60 { return 3 }
            return 3
        case .lowestLatency:
            if frameRate >= 120 { return 2 }
            if frameRate >= 60 { return 2 }
            return 1
        }
    }

    /// Returns the maximum simultaneous VideoToolbox encodes allowed for a latency profile.
    static func inFlightCap(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return frameRate >= 120 ? 2 : 1 }
        switch latencyMode {
        case .balanced:
            if frameRate >= 90 { return 3 }
            return 2
        case .smoothest:
            if frameRate >= 120 { return 8 }
            if frameRate >= 60 { return 3 }
            return 2
        case .lowestLatency:
            if frameRate >= 120 { return 2 }
            return 1
        }
    }

    /// Returns the initial in-flight target before adaptive quality/cadence tuning changes it.
    static func minInFlightFrames(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return 1 }
        switch latencyMode {
        case .balanced:
            if frameRate >= 90 { return 2 }
            return 1
        case .smoothest:
            if frameRate >= 120 { return 2 }
            if frameRate >= 90 { return 2 }
            if frameRate >= 60 { return 2 }
            return 1
        case .lowestLatency:
            return 1
        }
    }

    /// Returns whether desktop 60 Hz lowest-latency streams use the standard two-frame buffer policy.
    static func usesStandardDesktopLowLatency60HzBufferPolicy(
        streamKind: VideoEncoder.StreamKind,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .freshestFrame
    )
    -> Bool {
        streamKind == .desktop &&
            hostBufferingPolicy == .stability &&
            latencyMode == .lowestLatency &&
            frameRate == 60
    }

    /// Returns the low-latency in-flight cap after desktop-specific policy overrides.
    static func lowLatencyPipelineInFlightLimit(
        streamKind: VideoEncoder.StreamKind,
        frameRate: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .freshestFrame
    ) -> Int {
        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            return 1
        }
        if latencyMode == .balanced, hostBufferingPolicy == .freshestFrame {
            return frameRate >= 90 ? 3 : 2
        }
        if usesStandardDesktopLowLatency60HzBufferPolicy(
            streamKind: streamKind,
            frameRate: frameRate,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy
        ) {
            return 2
        }
        return frameRate >= 120 ? 2 : 1
    }
}
#endif
