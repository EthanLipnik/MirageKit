//
//  StreamFrameInboxTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitHost
import CoreMedia
import CoreVideo
import MirageKit
import Testing

#if os(macOS)
@Suite("Stream Frame Inbox")
struct StreamFrameInboxTests {
    @Test("Newest-first drain returns freshest frame and reports stale backlog drops")
    func newestDrainReturnsFreshestFrame() throws {
        let inbox = StreamFrameInbox(capacity: 4)
        inbox.enqueue(try makeFrame(captureTime: 1))
        inbox.enqueue(try makeFrame(captureTime: 2))
        inbox.enqueue(try makeFrame(captureTime: 3))

        let drainResult = inbox.takeNext(policy: .newest)

        #expect(drainResult.frame?.captureTime == 3)
        #expect(drainResult.droppedBeforeDelivery == 2)
        #expect(inbox.pendingCount() == 0)
    }

    @Test("FIFO drain preserves enqueue order")
    func fifoDrainPreservesOrder() throws {
        let inbox = StreamFrameInbox(capacity: 4)
        inbox.enqueue(try makeFrame(captureTime: 1))
        inbox.enqueue(try makeFrame(captureTime: 2))

        let first = inbox.takeNext(policy: .fifo)
        let second = inbox.takeNext(policy: .fifo)

        #expect(first.frame?.captureTime == 1)
        #expect(first.droppedBeforeDelivery == 0)
        #expect(second.frame?.captureTime == 2)
        #expect(second.droppedBeforeDelivery == 0)
        #expect(inbox.pendingCount() == 0)
    }

    @Test("Enqueue marks the inbox as scheduled until a drain completes")
    func enqueueMarksScheduledUntilDrainCompletes() throws {
        let inbox = StreamFrameInbox(capacity: 2)

        #expect(inbox.enqueue(try makeFrame(captureTime: 1)) == true)
        #expect(inbox.scheduleIfNeeded() == false)

        inbox.markDrainComplete()

        #expect(inbox.scheduleIfNeeded() == true)
    }

    private func makeFrame(captureTime: CFAbsoluteTime) throws -> CapturedFrame {
        let buffer = try #require(makePixelBuffer())
        return CapturedFrame(
            pixelBuffer: buffer,
            presentationTime: CMTime(seconds: captureTime, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 60),
            captureTime: captureTime,
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                dirtyPercentage: 100,
                isIdleFrame: false
            )
        )
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
#endif
