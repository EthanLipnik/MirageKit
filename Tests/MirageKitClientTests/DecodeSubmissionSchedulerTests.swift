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
    @Test("Scheduler escalates to three in-flight slots during sustained decode-bound stress")
    func escalatesOnDecodeBoundStress() async {
        let controller = StreamController(streamID: 900, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 56)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 3)
        await controller.stop()
    }

    @Test("Source-bound stress does not escalate decode submission limit")
    func sourceBoundStressDoesNotEscalate() async {
        let controller = StreamController(streamID: 901, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< (StreamController.decodeSubmissionStressWindows + 2) {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 40)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }

    @Test("Scheduler keeps baseline slots after sustained recovery")
    func recoversAfterHealthyWindows() async {
        let controller = StreamController(streamID: 902, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 56)
        }
        for _ in 0 ..< StreamController.decodeSubmissionHealthyWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 60, receivedFPS: 60)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }

    @Test("Unchanged target refresh update does not reset elevated submission limit")
    func unchangedTargetUpdateDoesNotResetElevatedLimit() async {
        let controller = StreamController(streamID: 903, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 56)
        }
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 3)

        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 3)
        await controller.stop()
    }
}
#endif
