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
        hostBufferDepth: MirageMedia.MirageHostBufferDepth = .standard,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        useLowLatencyPipeline: Bool
    ) -> StreamBufferPolicy {
        if mediaPathProfile.usesAwdlRadioPolicy {
            return awdlInteractiveDisplayBufferPolicy(
                streamKind: streamKind
            )
        }

        let basePolicy: StreamBufferPolicy
        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            let highRefresh = frameRate >= 90
            basePolicy = StreamBufferPolicy(
                bufferDepth: highRefresh ? 4 : 1,
                initialInFlightFrames: highRefresh ? 3 : 1,
                minimumInFlightFrames: highRefresh ? 3 : 1,
                maxInFlightFramesCap: highRefresh ? 3 : 1
            )
        } else if latencyMode == .balanced, hostBufferingPolicy == .freshestFrame {
            let highRefresh = frameRate >= 90
            let cap = highRefresh ? 3 : 2
            let initialInFlight = highRefresh ? 2 : 1
            basePolicy = StreamBufferPolicy(
                bufferDepth: cap,
                initialInFlightFrames: initialInFlight,
                minimumInFlightFrames: initialInFlight,
                maxInFlightFramesCap: cap
            )
        } else {
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
            basePolicy = StreamBufferPolicy(
                bufferDepth: bufferDepth,
                initialInFlightFrames: min(minInFlight, resolvedInFlightCap),
                minimumInFlightFrames: minInFlight,
                maxInFlightFramesCap: resolvedInFlightCap
            )
        }

        return adjustedBufferPolicy(
            basePolicy,
            frameRate: frameRate,
            latencyMode: latencyMode,
            hostBufferDepth: hostBufferDepth
        )
    }

    /// Returns the host pipeline depth for AWDL interactive display streams.
    static func awdlInteractiveDisplayBufferPolicy(
        streamKind: VideoEncoder.StreamKind
    ) -> StreamBufferPolicy {
        let isDesktopLike = streamKind == .desktop || streamKind == .appAtlas
        return StreamBufferPolicy(
            bufferDepth: isDesktopLike ? 3 : 2,
            initialInFlightFrames: isDesktopLike ? 2 : 1,
            minimumInFlightFrames: isDesktopLike ? 2 : 1,
            maxInFlightFramesCap: isDesktopLike ? 3 : 2
        )
    }

    private static func adjustedBufferPolicy(
        _ policy: StreamBufferPolicy,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode,
        hostBufferDepth: MirageHostBufferDepth
    ) -> StreamBufferPolicy {
        switch hostBufferDepth {
        case .standard:
            return policy
        case .minimal:
            let limits = minimalBufferLimits(latencyMode: latencyMode)
            let cap = min(max(1, policy.maxInFlightFramesCap), limits.maxInFlightFramesCap)
            let minimum = min(max(1, policy.minimumInFlightFrames), cap)
            let initial = min(max(minimum, policy.initialInFlightFrames), cap)
            let depth = max(cap, min(max(1, policy.bufferDepth), limits.bufferDepth))
            return StreamBufferPolicy(
                bufferDepth: depth,
                initialInFlightFrames: initial,
                minimumInFlightFrames: minimum,
                maxInFlightFramesCap: cap
            )
        case .high, .maximum:
            let increment = hostBufferDepth == .high ? 1 : 2
            let limits = maximumBufferLimits(frameRate: frameRate, latencyMode: latencyMode)
            let baseCap = max(1, policy.maxInFlightFramesCap)
            let cap = min(limits.maxInFlightFramesCap, baseCap + increment)
            let minimum = min(cap, max(1, policy.minimumInFlightFrames + increment))
            let initial = min(cap, max(minimum, policy.initialInFlightFrames + increment))
            let depth = min(limits.bufferDepth, max(cap, policy.bufferDepth + increment))
            return StreamBufferPolicy(
                bufferDepth: depth,
                initialInFlightFrames: initial,
                minimumInFlightFrames: minimum,
                maxInFlightFramesCap: cap
            )
        }
    }

    private static func minimalBufferLimits(
        latencyMode: MirageStreamLatencyMode
    ) -> (bufferDepth: Int, maxInFlightFramesCap: Int) {
        switch latencyMode {
        case .lowestLatency:
            (1, 1)
        case .balanced:
            (2, 2)
        case .smoothest:
            (3, 3)
        }
    }

    private static func maximumBufferLimits(
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> (bufferDepth: Int, maxInFlightFramesCap: Int) {
        switch latencyMode {
        case .lowestLatency:
            frameRate >= 90 ? (6, 5) : (3, 3)
        case .balanced:
            frameRate >= 90 ? (8, 6) : (5, 4)
        case .smoothest:
            (16, 10)
        }
    }

    private static func adjustedLowLatencyPipelineInFlightLimit(
        _ limit: Int,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode,
        hostBufferDepth: MirageHostBufferDepth
    ) -> Int {
        switch hostBufferDepth {
        case .standard:
            return max(1, limit)
        case .minimal:
            let limits = minimalBufferLimits(latencyMode: latencyMode)
            return min(max(1, limit), limits.maxInFlightFramesCap)
        case .high, .maximum:
            let increment = hostBufferDepth == .high ? 1 : 2
            let limits = maximumBufferLimits(frameRate: frameRate, latencyMode: latencyMode)
            return min(limits.maxInFlightFramesCap, max(1, limit + increment))
        }
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
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .freshestFrame,
        hostBufferDepth: MirageMedia.MirageHostBufferDepth = .standard
    ) -> Int {
        let baseLimit: Int
        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            baseLimit = frameRate >= 90 ? 3 : 1
        } else if latencyMode == .balanced, hostBufferingPolicy == .freshestFrame {
            baseLimit = frameRate >= 90 ? 3 : 2
        } else if usesStandardDesktopLowLatency60HzBufferPolicy(
            streamKind: streamKind,
            frameRate: frameRate,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy
        ) {
            baseLimit = 2
        } else {
            baseLimit = frameRate >= 120 ? 2 : 1
        }
        return adjustedLowLatencyPipelineInFlightLimit(
            baseLimit,
            frameRate: frameRate,
            latencyMode: latencyMode,
            hostBufferDepth: hostBufferDepth
        )
    }
}
#endif
