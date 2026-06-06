//
//  StreamContextFullFrameHostPipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit
@testable import MirageKitHost
import Testing
import MirageCore
import MirageMedia
import MirageWire

@Suite("StreamContext Full-Frame Host Pipeline")
struct StreamContextFullFrameHostPipelineTests {
    @Test("Full-frame host pipeline reports current single-unit topology")
    func fullFrameHostPipelineReportsCurrentSingleUnitTopology() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "FC2A5034-D314-45E0-A816-F97D7286E247"))
        )
        let context = makeContext(streamID: 81, codec: .hevc)
        await context.configureForFullFramePipelineTest(
            baseSize: CGSize(width: 2560, height: 1440),
            captureSize: CGSize(width: 1920, height: 1080),
            encodedSize: CGSize(width: 1280, height: 720)
        )

        let pipeline = context.fullFrameHostPipeline(topologyID: topologyID)
        let topology = await pipeline.currentTopology()

        #expect(topology.id == topologyID)
        #expect(topology.kind == .singleUnit)
        #expect(topology.logicalSize == MiragePixelSize(width: 1280, height: 720))
        #expect(topology.representsSingleUnitFullFrame)
        #expect(topology.units.map(\.id) == [MirageMediaUnitID.primary])
        #expect(topology.units.first?.codec == .hevc)
    }

    @Test("Full-frame host pipeline falls back to capture size when encoded size is not known")
    func fullFrameHostPipelineFallsBackToCaptureSizeWhenEncodedSizeIsNotKnown() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "B9C0F7BE-A880-441B-B79F-70EE7F0707E8"))
        )
        let context = makeContext(streamID: 82, codec: .proRes4444)
        await context.configureForFullFramePipelineTest(
            baseSize: CGSize(width: 1440, height: 900),
            captureSize: CGSize(width: 1600, height: 900),
            encodedSize: .zero
        )

        let topology = await context.fullFrameHostPipeline(topologyID: topologyID).currentTopology()

        #expect(topology.logicalSize == MiragePixelSize(width: 1600, height: 900))
        #expect(topology.units.first?.codec == .proRes4444)
    }

    @Test("Full-frame host pipeline validates wrapped context startup state")
    func fullFrameHostPipelineValidatesWrappedContextStartupState() async throws {
        let running = makeContext(streamID: 83)
        await running.configureForFullFramePipelineTest(running: true)
        try await running.fullFrameHostPipeline().start()

        let stopped = makeContext(streamID: 84)
        await stopped.configureForFullFramePipelineTest(running: false)
        let stoppedPipeline = stopped.fullFrameHostPipeline()

        await #expect(throws: StreamContextFullFrameHostPipelineError.streamContextNotRunning(84)) {
            try await stoppedPipeline.start()
        }
    }

    @Test("Full-frame host pipeline forwards submitted frames through StreamContext admission")
    func fullFrameHostPipelineForwardsSubmittedFramesThroughStreamContextAdmission() async throws {
        let context = makeContext(streamID: 85)
        await context.configureForFullFramePipelineTest(running: true, shouldEncodeFrames: false)
        let frame = try makeCapturedFrame(isIdleFrame: false)

        await context.fullFrameHostPipeline().submit(frame)
        try await waitForCaptureIngress(on: context)

        let snapshot = await context.fullFramePipelineTestSnapshot()
        #expect(snapshot.captureIngressCount == 1)
        #expect(snapshot.lastCapturedFrameTime > 0)
        #expect(snapshot.hasCachedStartupFrame)
    }

    @Test("Full-frame host pipeline shared encode callback preserves current wire output")
    func fullFrameHostPipelineSharedEncodeCallbackPreservesCurrentWireOutput() async throws {
        let payload = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99])
        let contentRect = CGRect(x: 12, y: 24, width: 640, height: 360)
        let captured = Locked<[CapturedHostPipelinePacket]>([])
        let context = makeContext(
            streamID: 89,
            maxPacketSize: MirageWire.mirageMosaicHeaderSize + MirageMediaSecurity.authTagLength + 4,
            additionalFrameFlags: [.desktopStream]
        )
        let encoder = VideoEncoder(
            configuration: MirageEncoderConfiguration.highQuality,
            latencyMode: .lowestLatency
        )
        await context.setupPacketSender { packet, metadata, onComplete in
            captured.withLock {
                $0.append(CapturedHostPipelinePacket(packet: packet, metadata: metadata))
            }
            onComplete(nil)
        }
        await context.configureForFullFrameEncodedCallbackTest(
            encoder: encoder,
            contentRect: contentRect,
            dimensionToken: 23,
            epoch: 4
        )
        await context.startEncoderWithSharedCallback(
            pinnedContentRect: nil,
            logPrefix: "Pipeline test"
        )

        await encoder.emitFullFramePipelineTestEncodedFrame(
            payload,
            isKeyframe: true,
            presentationTime: CMTime(seconds: 4, preferredTimescale: 600)
        )

        let packets = try await waitForHostPipelinePackets(captured, expectedCount: 3)
            .sorted { $0.metadata.fragmentIndex < $1.metadata.fragmentIndex }
        try await waitForStreamPacketQueuedBytesToDrain(try #require(await context.packetSender))
        await context.stop()

        try assertHostPipelineMosaicPacket(
            packets[0],
            payload: payload,
            payloadRange: 0 ..< 4,
            expectedSequence: 0,
            expectedFragmentIndex: 0,
            expectedFlags: MirageWire.MirageMosaicPacketFlags([.keyframe, .parameterSet, .atomicGroup])
        )
        try assertHostPipelineMosaicPacket(
            packets[1],
            payload: payload,
            payloadRange: 4 ..< 8,
            expectedSequence: 1,
            expectedFragmentIndex: 1,
            expectedFlags: MirageWire.MirageMosaicPacketFlags([.keyframe, .atomicGroup])
        )
        try assertHostPipelineMosaicPacket(
            packets[2],
            payload: payload,
            payloadRange: 8 ..< 10,
            expectedSequence: 2,
            expectedFragmentIndex: 2,
            expectedFlags: MirageWire.MirageMosaicPacketFlags([.keyframe, .endOfUnit, .atomicGroup])
        )
    }

    @Test("Full-frame host pipeline maps recovery to current keyframe requests")
    func fullFrameHostPipelineMapsRecoveryToCurrentKeyframeRequests() async {
        let context = makeContext(streamID: 86)
        await context.configureForFullFramePipelineTest(running: true, shouldEncodeFrames: true)
        let pipeline = context.fullFrameHostPipeline()

        await pipeline.requestRecovery(
            MirageRecoveryRequest(scope: .fullStream(999), cause: .manual)
        )
        #expect(await context.fullFramePipelineTestSnapshot().pendingKeyframeReason == nil)

        await pipeline.requestRecovery(
            MirageRecoveryRequest(scope: .fullStream(86), cause: .presentationStall)
        )

        let snapshot = await context.fullFramePipelineTestSnapshot()
        #expect(snapshot.pendingKeyframeReason == "Keyframe request")
        #expect(snapshot.latestRecoveryCause == .freezeTimeout)
        #expect(snapshot.softRecoveryCount == 1)
    }

    @Test("Full-frame host pipeline filters recovery to the current primary unit")
    func fullFrameHostPipelineFiltersRecoveryToCurrentPrimaryUnit() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "53B2ED52-0598-47AE-AFE2-A5DD7FC8E254"))
        )
        let context = makeContext(streamID: 88)
        await context.configureForFullFramePipelineTest(running: true, shouldEncodeFrames: true)
        let pipeline = context.fullFrameHostPipeline(topologyID: topologyID)

        await pipeline.requestRecovery(
            MirageRecoveryRequest(
                scope: MirageRecoveryScope(
                    streamID: 88,
                    topologyID: MirageMediaTopologyID(),
                    mediaUnitID: .primary
                ),
                cause: .manual
            )
        )
        await pipeline.requestRecovery(
            MirageRecoveryRequest(
                scope: MirageRecoveryScope(
                    streamID: 88,
                    topologyID: topologyID,
                    mediaUnitID: MirageMediaUnitID(rawValue: "secondary")
                ),
                cause: .manual
            )
        )

        var snapshot = await context.fullFramePipelineTestSnapshot()
        #expect(snapshot.pendingKeyframeReason == nil)
        #expect(snapshot.softRecoveryCount == 0)

        await pipeline.requestRecovery(
            MirageRecoveryRequest(
                scope: MirageRecoveryScope(
                    streamID: 88,
                    topologyID: topologyID,
                    mediaUnitID: .primary
                ),
                cause: .manual
            )
        )

        snapshot = await context.fullFramePipelineTestSnapshot()
        #expect(snapshot.pendingKeyframeReason == "Keyframe request")
        #expect(snapshot.latestRecoveryCause == .manual)
        #expect(snapshot.softRecoveryCount == 1)
    }

    @Test("Full-frame host pipeline preserves current recovery cause mapping")
    func fullFrameHostPipelinePreservesCurrentRecoveryCauseMapping() async {
        let cases: [(MirageRecoveryCause, MirageWire.MirageMediaFeedbackRecoveryCause)] = [
            (.startup, .startupTimeout),
            (.keyframeLoss, .decodeError),
            (.presentationStall, .freezeTimeout),
            (.resize, .manual),
            (.manual, .manual),
        ]

        for (index, recoveryCase) in cases.enumerated() {
            let streamID = StreamID(100 + index)
            let context = makeContext(streamID: streamID)
            await context.configureForFullFramePipelineTest(running: true, shouldEncodeFrames: true)
            await context.fullFrameHostPipeline().requestRecovery(
                MirageRecoveryRequest(scope: .fullStream(streamID), cause: recoveryCase.0)
            )

            let snapshot = await context.fullFramePipelineTestSnapshot()
            #expect(snapshot.pendingKeyframeReason == "Keyframe request")
            #expect(snapshot.latestRecoveryCause == recoveryCase.1)
            #expect(snapshot.softRecoveryCount == 1)
        }
    }

    @Test("Full-frame host pipeline stops the wrapped context")
    func fullFrameHostPipelineStopsWrappedContext() async {
        let context = makeContext(streamID: 87)
        await context.configureForFullFramePipelineTest(running: true)

        await context.fullFrameHostPipeline().stop()

        #expect(await context.fullFramePipelineTestSnapshot().isRunning == false)
    }
}

private struct FullFramePipelineContextSnapshot: Sendable {
    let isRunning: Bool
    let captureIngressCount: UInt64
    let lastCapturedFrameTime: CFAbsoluteTime
    let hasCachedStartupFrame: Bool
    let pendingKeyframeReason: String?
    let latestRecoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause
    let softRecoveryCount: UInt64
}

private struct CapturedHostPipelinePacket: Sendable {
    let packet: Data
    let metadata: StreamPacketSender.TransportPacketMetadata
}

private enum FullFramePipelineTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case captureIngressTimedOut
    case packetCaptureTimedOut
}

private func makeContext(
    streamID: StreamID,
    codec: MirageMedia.MirageVideoCodec = .hevc,
    maxPacketSize: Int = MirageWire.mirageDefaultMaxPacketSize,
    additionalFrameFlags: MirageWire.FrameFlags = []
) -> StreamContext {
    var encoderConfig = MirageEncoderConfiguration.highQuality
    encoderConfig.codec = codec
    return StreamContext(
        streamID: streamID,
        windowID: 9,
        encoderConfig: encoderConfig,
        streamScale: 1.0,
        maxPacketSize: maxPacketSize,
        additionalFrameFlags: additionalFrameFlags
    )
}

private func makeCapturedFrame(isIdleFrame: Bool) throws -> CapturedFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        64,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw FullFramePipelineTestError.pixelBufferCreationFailed(status)
    }
    return CapturedFrame(
        pixelBuffer: pixelBuffer,
        presentationTime: CMTime(value: 1, timescale: 60),
        duration: CMTime(value: 1, timescale: 60),
        captureTime: CFAbsoluteTimeGetCurrent(),
        info: CapturedFrameInfo(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            dirtyPercentage: isIdleFrame ? 0 : 100,
            isIdleFrame: isIdleFrame
        )
    )
}

private func waitForCaptureIngress(on context: StreamContext) async throws {
    for _ in 0 ..< 20 {
        if await context.fullFramePipelineTestSnapshot().captureIngressCount > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw FullFramePipelineTestError.captureIngressTimedOut
}

private func waitForHostPipelinePackets(
    _ captured: Locked<[CapturedHostPipelinePacket]>,
    expectedCount: Int
) async throws -> [CapturedHostPipelinePacket] {
    for _ in 0 ..< 100 {
        let packets = captured.read { $0 }
        if packets.count >= expectedCount {
            return packets
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw FullFramePipelineTestError.packetCaptureTimedOut
}

private func assertHostPipelinePacket(
    _ packet: CapturedHostPipelinePacket,
    payload: Data,
    payloadRange: Range<Int>,
    contentRect: CGRect,
    expectedSequence: UInt32,
    expectedFragmentIndex: Int,
    expectedFlags: MirageWire.FrameFlags
) throws {
    let header = try #require(MirageWire.FrameHeader.deserialize(from: packet.packet))
    let expectedPayload = Data(payload[payloadRange])
    let wirePayload = Data(packet.packet.dropFirst(MirageWire.mirageHeaderSize))

    #expect(packet.packet.count == MirageWire.mirageHeaderSize + expectedPayload.count)
    #expect(wirePayload == expectedPayload)
    #expect(header.magic == MirageWire.mirageProtocolMagic)
    #expect(header.version == MirageKit.mediaPacketProtocolVersion)
    #expect(header.streamID == 89)
    #expect(header.sequenceNumber == expectedSequence)
    #expect(header.timestamp == 4_000_000_000)
    #expect(header.frameNumber == 0)
    #expect(header.fragmentIndex == UInt16(expectedFragmentIndex))
    #expect(header.fragmentCount == 3)
    #expect(header.fecBlockSize == 0)
    #expect(header.payloadLength == UInt32(expectedPayload.count))
    #expect(header.frameByteCount == UInt32(payload.count))
    #expect(header.checksum == MirageWire.CRC32.calculate(expectedPayload))
    #expect(header.contentRect == contentRect)
    #expect(header.dimensionToken == 23)
    #expect(header.epoch == 4)
    #expect(header.flags == expectedFlags)
    #expect(!header.flags.contains(.fecParity))
    #expect(!header.flags.contains(.encryptedPayload))

    #expect(packet.metadata.streamID == 89)
    #expect(packet.metadata.frameNumber == 0)
    #expect(packet.metadata.fragmentIndex == expectedFragmentIndex)
    #expect(packet.metadata.fragmentCount == 3)
    #expect(packet.metadata.isKeyframe)
    #expect(!packet.metadata.isParity)
    #expect(!packet.metadata.isRecovery)
}

private func assertHostPipelineMosaicPacket(
    _ packet: CapturedHostPipelinePacket,
    payload: Data,
    payloadRange: Range<Int>,
    expectedSequence: UInt32,
    expectedFragmentIndex: Int,
    expectedFlags: MirageWire.MirageMosaicPacketFlags
) throws {
    let header = try #require(MirageWire.MirageMosaicPacketHeader.deserialize(from: packet.packet))
    let expectedPayload = Data(payload[payloadRange])
    let wirePayload = Data(packet.packet.dropFirst(MirageWire.mirageMosaicHeaderSize))

    #expect(packet.packet.count == MirageWire.mirageMosaicHeaderSize + expectedPayload.count)
    #expect(wirePayload == expectedPayload)
    #expect(header.magic == MirageWire.mirageMosaicMediaMagic)
    #expect(header.version == MirageKit.mediaPacketProtocolVersion)
    #expect(header.streamID == 89)
    #expect(header.packetSequence == expectedSequence)
    #expect(header.timestamp == 4_000_000_000)
    #expect(header.tilePlanEpoch == 4)
    #expect(header.mediaEpoch == 23)
    #expect(header.mediaUnitIndex == 0)
    #expect(header.tileIndex == 0)
    #expect(header.transportGroupIndex == 0)
    #expect(header.presentationGroupIndex == 0)
    #expect(header.unitFrameNumber == 0)
    #expect(header.fragmentIndex == UInt16(expectedFragmentIndex))
    #expect(header.fragmentCount == 3)
    #expect(header.fecBlockSize == 0)
    #expect(header.payloadLength == UInt32(expectedPayload.count))
    #expect(header.unitByteCount == UInt32(payload.count))
    #expect(header.checksum == MirageWire.CRC32.calculate(expectedPayload))
    #expect(header.flags == expectedFlags)
    #expect(!header.flags.contains(.fecParity))
    #expect(!header.flags.contains(.encryptedPayload))

    #expect(packet.metadata.streamID == 89)
    #expect(packet.metadata.frameNumber == 0)
    #expect(packet.metadata.fragmentIndex == expectedFragmentIndex)
    #expect(packet.metadata.fragmentCount == 3)
    #expect(packet.metadata.isKeyframe)
    #expect(!packet.metadata.isParity)
    #expect(!packet.metadata.isRecovery)
}

private extension StreamContext {
    func configureForFullFramePipelineTest(
        baseSize: CGSize = CGSize(width: 1920, height: 1080),
        captureSize: CGSize = CGSize(width: 1920, height: 1080),
        encodedSize: CGSize = CGSize(width: 1920, height: 1080),
        running: Bool = true,
        shouldEncodeFrames: Bool = false
    ) {
        isRunning = running
        useVirtualDisplay = false
        self.shouldEncodeFrames = shouldEncodeFrames
        startupFrameCachingEnabled = !shouldEncodeFrames
        baseCaptureSize = baseSize
        currentCaptureSize = captureSize
        currentEncodedSize = encodedSize
        currentContentRect = CGRect(origin: .zero, size: encodedSize == .zero ? captureSize : encodedSize)
    }

    func configureForFullFrameEncodedCallbackTest(
        encoder: VideoEncoder,
        contentRect: CGRect,
        dimensionToken: UInt16,
        epoch: UInt16
    ) {
        isRunning = true
        shouldEncodeFrames = true
        startupFrameCachingEnabled = false
        useVirtualDisplay = false
        currentContentRect = contentRect
        currentCaptureSize = contentRect.size
        currentEncodedSize = contentRect.size
        self.dimensionToken = dimensionToken
        self.epoch = epoch
        self.encoder = encoder
    }

    func fullFramePipelineTestSnapshot() -> FullFramePipelineContextSnapshot {
        FullFramePipelineContextSnapshot(
            isRunning: isRunning,
            captureIngressCount: captureIngressIntervalCount,
            lastCapturedFrameTime: lastCapturedFrameTime,
            hasCachedStartupFrame: cachedStartupFrame != nil,
            pendingKeyframeReason: pendingKeyframeReason,
            latestRecoveryCause: latestReceiverRecoveryCause,
            softRecoveryCount: softRecoveryCount
        )
    }
}

private extension VideoEncoder {
    func emitFullFramePipelineTestEncodedFrame(
        _ data: Data,
        isKeyframe: Bool,
        presentationTime: CMTime
    ) {
        encodedFrameHandler?(data, isKeyframe, presentationTime, {})
    }
}
#endif
