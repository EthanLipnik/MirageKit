//
//  DecodeSubmissionSchedulerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Coverage for conservative adaptive decode submission scheduling.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Decode Submission Scheduler")
struct DecodeSubmissionSchedulerTests {
    @Test("60 Hz low-latency stays single submission under decode-bound stress")
    func lowLatencySixtyHertzStaysSingleSubmissionUnderStress() async {
        let controller = StreamController(streamID: 900, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 1)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 56)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 1)
        await controller.stop()
    }

    @Test("Source-bound stress does not escalate decode submission limit")
    func sourceBoundStressDoesNotEscalate() async {
        let controller = StreamController(streamID: 901, maxPayloadSize: 1200)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 1)

        for _ in 0 ..< (StreamController.decodeSubmissionStressWindows + 2) {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 40, receivedFPS: 40)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 1)
        await controller.stop()
    }

    @Test("High-FPS Smoothest starts at two decode submissions")
    func highFPSSmoothestStartsAtTwoDecodeSubmissions() async {
        let controller = StreamController(streamID: 902, maxPayloadSize: 1200)
        await controller.updateCadenceTarget(
            sourceFPS: 120,
            displayFPS: 120,
            latencyMode: .smoothest,
            reason: "test"
        )
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 70, receivedFPS: 118)
        }

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 2)
        await controller.stop()
    }

    @Test("Switching back to 60 Hz clamps an existing high-FPS limit")
    func switchingBackToSixtyHertzClampsHighFPSLimit() async {
        let controller = StreamController(streamID: 903, maxPayloadSize: 1200)
        await controller.updateCadenceTarget(
            sourceFPS: 120,
            displayFPS: 120,
            latencyMode: .smoothest,
            reason: "test high fps"
        )
        for _ in 0 ..< StreamController.decodeSubmissionStressWindows {
            await controller.evaluateDecodeSubmissionLimit(decodedFPS: 70, receivedFPS: 118)
        }
        #expect(await controller.decoder.currentDecodeSubmissionLimit() == 2)

        await controller.updateCadenceTarget(
            sourceFPS: 60,
            displayFPS: 60,
            latencyMode: .smoothest,
            reason: "test 60 fps"
        )

        let decoderLimit = await controller.decoder.currentDecodeSubmissionLimit()
        #expect(decoderLimit == 1)
        await controller.stop()
    }
}
#endif
