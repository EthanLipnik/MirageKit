//
//  StreamContextFullFrameHostPipeline.swift
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
import CoreGraphics
import Foundation

#if os(macOS)

enum StreamContextFullFrameHostPipelineError: Error, Equatable {
    case streamContextNotRunning(StreamID)
}

/// Adapts the current single-stream host pipeline to the topology-aware media contract.
actor StreamContextFullFrameHostPipeline: MirageHostMediaPipeline {
    private let context: StreamContext
    private let topologyID: MirageMediaTopologyID

    init(
        context: StreamContext,
        topologyID: MirageMediaTopologyID = MirageMediaTopologyID()
    ) {
        self.context = context
        self.topologyID = topologyID
    }

    func currentTopology() async -> MirageMediaTopology {
        await context.fullFrameMediaTopology(id: topologyID)
    }

    func start() async throws {
        let streamID = context.streamID
        guard await context.isRunning else {
            throw StreamContextFullFrameHostPipelineError.streamContextNotRunning(streamID)
        }
    }

    func submit(_ frame: CapturedFrame) async {
        context.enqueueCapturedFrame(frame)
    }

    func requestRecovery(_ request: MirageRecoveryRequest) async {
        guard context.streamID == request.scope.streamID else { return }
        guard request.scope.topologyID == nil || request.scope.topologyID == topologyID else { return }
        guard request.scope.mediaUnitID == nil || request.scope.mediaUnitID == .primary else { return }
        _ = await context.requestKeyframe(recoveryCause: request.cause.mediaFeedbackRecoveryCause)
    }

    func stop() async {
        await context.stop()
    }
}

extension StreamContext {
    nonisolated func fullFrameHostPipeline(
        topologyID: MirageMediaTopologyID = MirageMediaTopologyID()
    ) -> StreamContextFullFrameHostPipeline {
        StreamContextFullFrameHostPipeline(context: self, topologyID: topologyID)
    }

    func fullFrameMediaTopology(id: MirageMediaTopologyID) -> MirageMediaTopology {
        MirageMediaTopology.singleUnit(
            id: id,
            logicalSize: fullFrameTopologyPixelSize,
            codec: encoderConfig.codec
        )
    }

    private var fullFrameTopologyPixelSize: MiragePixelSize {
        let size = firstNonEmptySize(
            currentEncodedSize,
            currentCaptureSize,
            baseCaptureSize
        )
        return MiragePixelSize(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }

    private func firstNonEmptySize(_ sizes: CGSize...) -> CGSize {
        for size in sizes where size.width > 0 && size.height > 0 {
            return size
        }
        return .zero
    }
}

private extension MirageRecoveryCause {
    var mediaFeedbackRecoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause {
        switch self {
        case .startup:
            .startupTimeout
        case .keyframeLoss:
            .decodeError
        case .presentationStall:
            .freezeTimeout
        case .resize,
             .manual:
            .manual
        }
    }
}

#endif
