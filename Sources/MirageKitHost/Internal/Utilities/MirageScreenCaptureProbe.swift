//
//  MirageScreenCaptureProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  ScreenCaptureKit-based quality probe using a hidden virtual display.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit
import Network

enum MirageScreenCaptureProbe {
    private static let displayLease = QualityProbeDisplayLease()

    struct Result {
        let encodeMs: Double?
        let observedBitrateBps: Int?
    }

    static func runVirtualDisplayProbe(
        resolution: CGSize,
        frameRate: Int,
        pixelFormat: MiragePixelFormat,
        targetBitrateBps: Int,
        transportConfig: QualityProbeTransportConfig? = nil,
        maxPacketSize: Int = mirageDefaultMaxPacketSize,
        transportConnection: NWConnection? = nil
    ) async throws -> Result {
        let sanitizedFrameRate = max(1, frameRate)
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: sanitizedFrameRate)
        let colorSpace: MirageColorSpace = isTenBit(pixelFormat) ? .displayP3 : .sRGB
        let targetResolution = CGSize(
            width: max(2, resolution.width),
            height: max(2, resolution.height)
        )

        let lease = try await displayLease.acquire(
            resolution: targetResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace
        )
        let patternWindow = await MainActor.run {
            MirageQualityProbeWindow(
                displayID: lease.snapshot.displayID,
                spaceID: lease.snapshot.spaceID,
                bounds: lease.displayBounds
            )
        }

        await MainActor.run { patternWindow.start() }

        let displayWrapper = try await SharedVirtualDisplayManager.shared.findSCDisplay(
            displayID: lease.snapshot.displayID,
            maxAttempts: 6
        )

        let width = max(2, Int(targetResolution.width.rounded(.down)))
        let height = max(2, Int(targetResolution.height.rounded(.down)))

        let config = MirageEncoderConfiguration(
            targetFrameRate: sanitizedFrameRate,
            keyFrameInterval: sanitizedFrameRate * 2,
            colorSpace: colorSpace,
            pixelFormat: pixelFormat,
            bitrate: max(0, targetBitrateBps)
        )

        let encoder = HEVCEncoder(
            configuration: config,
            latencyMode: .lowestLatency,
            inFlightLimit: 1
        )
        try await encoder.createSession(width: width, height: height)
        try await encoder.preheat()

        let captureEngine = WindowCaptureEngine(
            configuration: config,
            latencyMode: .lowestLatency,
            captureFrameRate: sanitizedFrameRate,
            usesDisplayRefreshCadence: true
        )

        let transportState = TransportProbeState()
        let transportPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        let packetSender: StreamPacketSender?
        if transportConfig != nil, let transportConnection {
            let onPacket: @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void = { data, _, release in
                transportConnection.send(content: data, completion: .contentProcessed { _ in
                    release()
                })
            }
            let sender = StreamPacketSender(maxPayloadSize: transportPayloadSize, onEncodedFrame: onPacket)
            await sender.start()
            await sender.setTargetBitrateBps(targetBitrateBps)
            packetSender = sender
        } else {
            packetSender = nil
        }

        func cleanup() async {
            await captureEngine.stopCapture()
            await encoder.stopEncoding()
            if let packetSender {
                await packetSender.stop()
            }
            await MainActor.run { patternWindow.stop() }
            await displayLease.release(displayID: lease.snapshot.displayID)
        }

        let onEncodedFrame: @Sendable (Data, Bool, CMTime) -> Void = { data, isKeyframe, presentationTime in
            transportState.recordEncodedBytes(data.count)

            guard let packetSender, let transportConfig else { return }
            let frameByteCount = data.count
            let dataFragments = (frameByteCount + transportPayloadSize - 1) / transportPayloadSize
            let counters = transportState.reserveSequenceNumbers(fragmentCount: dataFragments)

            let workItem = StreamPacketSender.WorkItem(
                encodedData: data,
                frameByteCount: frameByteCount,
                isKeyframe: isKeyframe || counters.isFirstFrame,
                presentationTime: presentationTime,
                contentRect: .zero,
                streamID: transportConfig.streamID,
                frameNumber: counters.frameNumber,
                sequenceNumberStart: counters.sequenceNumberStart,
                additionalFlags: [],
                dimensionToken: 0,
                epoch: 0,
                fecBlockSize: 0,
                wireBytes: frameByteCount,
                logPrefix: "ProbeFrame",
                generation: packetSender.currentGenerationSnapshot(),
                onSendStart: nil,
                onSendComplete: nil
            )
            packetSender.enqueue(workItem)
        }

        await encoder.startEncoding(onEncodedFrame: onEncodedFrame, onFrameComplete: {})

        do {
            try await captureEngine.startDisplayCapture(
                display: displayWrapper.display,
                resolution: CGSize(width: width, height: height),
                showsCursor: false
            ) { frame in
                Task.detached { [weak encoder] in
                    guard let encoder else { return }
                    _ = try? await encoder.encodeFrame(frame, forceKeyframe: false)
                }
            }

            let warmupDuration = Duration.milliseconds(250)
            try await Task.sleep(for: warmupDuration)

            let probeDuration = Duration.milliseconds(transportConfig?.durationMs ?? 2000)
            let startTime = CFAbsoluteTimeGetCurrent()
            try await Task.sleep(for: probeDuration)
            await captureEngine.stopCapture()
            await encoder.stopEncoding()

            let encodeMs = await encoder.getAverageEncodeTimeMs()
            let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
            let bytes = transportState.encodedBytesSnapshot()
            let observedBitrateBps = bytes > 0 ? Int((Double(bytes) * 8.0) / elapsed) : nil

            let result = Result(
                encodeMs: encodeMs > 0 ? encodeMs : nil,
                observedBitrateBps: observedBitrateBps
            )

            await cleanup()
            return result
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func isTenBit(_ format: MiragePixelFormat) -> Bool {
        switch format {
        case .p010, .bgr10a2:
            true
        case .bgra8, .nv12:
            false
        }
    }

    private final class TransportProbeState: @unchecked Sendable {
        struct SequenceCounters {
            let frameNumber: UInt32
            let sequenceNumberStart: UInt32
            let isFirstFrame: Bool
        }

        private let lock = NSLock()
        private var encodedBytes: Int = 0
        private var frameNumber: UInt32 = 0
        private var sequenceNumber: UInt32 = 0

        func recordEncodedBytes(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            encodedBytes += count
            lock.unlock()
        }

        func reserveSequenceNumbers(fragmentCount: Int) -> SequenceCounters {
            let totalFragments = max(1, fragmentCount)
            lock.lock()
            let currentFrame = frameNumber
            let isFirstFrame = currentFrame == 0
            let sequenceStart = sequenceNumber
            sequenceNumber &+= UInt32(totalFragments)
            frameNumber &+= 1
            lock.unlock()
            return SequenceCounters(
                frameNumber: currentFrame,
                sequenceNumberStart: sequenceStart,
                isFirstFrame: isFirstFrame
            )
        }

        func encodedBytesSnapshot() -> Int {
            lock.lock()
            let snapshot = encodedBytes
            lock.unlock()
            return snapshot
        }
    }

    private actor QualityProbeDisplayLease {
        struct Lease {
            let snapshot: SharedVirtualDisplayManager.DisplaySnapshot
            let displayBounds: CGRect
        }

        private var activeCount: Int = 0
        private var releaseTask: Task<Void, Never>?
        private var lastSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
        private let releaseDelay = Duration.milliseconds(1500)

        func acquire(
            resolution: CGSize,
            refreshRate: Int,
            colorSpace: MirageColorSpace
        )
        async throws -> Lease {
            releaseTask?.cancel()
            releaseTask = nil

            let snapshot = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                .qualityTest,
                resolution: resolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace,
                allowActiveUpdate: true
            )
            lastSnapshot = snapshot
            activeCount += 1

            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(for: snapshot.resolution)
            let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                snapshot.displayID,
                knownResolution: logicalResolution
            )

            await MainActor.run {
                VirtualDisplayKeepaliveController.shared.start(
                    displayID: snapshot.displayID,
                    spaceID: snapshot.spaceID,
                    refreshRate: snapshot.refreshRate
                )
            }

            return Lease(snapshot: snapshot, displayBounds: displayBounds)
        }

        func release(displayID: CGDirectDisplayID) async {
            activeCount = max(0, activeCount - 1)
            guard activeCount == 0 else { return }

            let resolvedDisplayID = lastSnapshot?.displayID ?? displayID
            releaseTask?.cancel()
            releaseTask = Task { [resolvedDisplayID, releaseDelay] in
                try? await Task.sleep(for: releaseDelay)
                await MainActor.run {
                    VirtualDisplayKeepaliveController.shared.stop(displayID: resolvedDisplayID)
                }
                await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.qualityTest)
                await SharedVirtualDisplayManager.shared.waitForDisplayRemoval(displayID: resolvedDisplayID)
            }
        }
    }

}

#endif
