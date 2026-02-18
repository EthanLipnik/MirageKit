//
//  DecodeSubmissionSchedulerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Coverage for adaptive decode submission scheduling with a 60Hz baseline of 2.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Decode Submission Scheduler")
struct DecodeSubmissionSchedulerTests {
    @Test("Scheduler escalates to three in-flight slots during sustained decode stress")
    func escalatesOnStress() async {
        let controller = StreamController(streamID: 900, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 3)
        await controller.stop()
    }

    @Test("Scheduler keeps baseline slots after sustained recovery")
    func recoversAfterHealthyWindows() async {
        let controller = StreamController(streamID: 901, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40)
        }
        for _ in 0 ..< StreamController.decodeSubmissionHealthyWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 60)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }

    @Test("Mid-band decode cadence keeps the baseline submission limit")
    func midBandDoesNotToggle() async {
        let controller = StreamController(streamID: 902, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< 8 {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 52)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }
}
#endif
