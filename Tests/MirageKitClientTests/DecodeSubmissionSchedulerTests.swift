//
//  DecodeSubmissionSchedulerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Coverage for adaptive decode submission scheduling (1 -> 2 -> 1).
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Decode Submission Scheduler")
struct DecodeSubmissionSchedulerTests {
    @Test("Scheduler escalates to two in-flight slots during sustained decode stress")
    func escalatesOnStress() async {
        let controller = StreamController(streamID: 900, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }

    @Test("Scheduler returns to one in-flight slot after sustained recovery")
    func recoversAfterHealthyWindows() async {
        let controller = StreamController(streamID: 901, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40)
        }
        for _ in 0 ..< StreamController.decodeSubmissionHealthyWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 60)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 1)
        await controller.stop()
    }

    @Test("Mid-band decode cadence does not toggle submission limit")
    func midBandDoesNotToggle() async {
        let controller = StreamController(streamID: 902, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)

        for _ in 0 ..< 8 {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 52)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 1)
        await controller.stop()
    }
}
#endif
