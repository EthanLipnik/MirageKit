//
//  VideoDecoderSessionRecreationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/7/26.
//

@testable import MirageKitClient
import Testing

@Suite("HEVC Decoder Session Recreation")
struct VideoDecoderSessionRecreationTests {
    @Test("Parameter-set changes recreate the decoder session even when dimensions stay constant")
    func parameterSetChangesTriggerSessionRecreation() {
        #expect(VideoDecoder.shouldRecreateSession(
            isFirstKeyframe: false,
            dimensionsChanged: false,
            parameterSetsChanged: true,
            shouldRecreateForErrors: false
        ))
    }

    @Test("First keyframe does not count as a format-change recreation")
    func firstKeyframeDoesNotForceRecreation() {
        #expect(!VideoDecoder.shouldRecreateSession(
            isFirstKeyframe: true,
            dimensionsChanged: false,
            parameterSetsChanged: true,
            shouldRecreateForErrors: false
        ))
    }

    @Test("Handled decode callback failures stay out of non-fatal diagnostics")
    func handledDecodeCallbackFailuresStayOutOfNonFatalDiagnostics() {
        #expect(VideoDecoder.shouldSuppressNonFatalCallbackFailure(status: -12909))
        #expect(VideoDecoder.shouldSuppressNonFatalCallbackFailure(status: -12911))
        #expect(VideoDecoder.shouldSuppressNonFatalCallbackFailure(status: -12903))
        #expect(VideoDecoder.shouldSuppressNonFatalCallbackFailure(status: -17694))
        #expect(VideoDecoder.shouldSuppressNonFatalCallbackFailure(status: -1) == false)
    }

    @Test("Only invalid-session and decoder-malfunction callback failures invalidate the session")
    func callbackFailureSessionInvalidationOnlyAppliesToPoisonedDecoderStates() {
        #expect(VideoDecoder.shouldInvalidateSessionAfterCallbackFailure(status: -12903))
        #expect(VideoDecoder.shouldInvalidateSessionAfterCallbackFailure(status: -12911))
        #expect(VideoDecoder.shouldInvalidateSessionAfterCallbackFailure(status: -12909) == false)
    }

    @Test("Stale decode callbacks are ignored after the decoder generation advances")
    func staleDecodeCallbacksAreIgnoredAfterGenerationAdvance() {
        #expect(VideoDecoder.shouldIgnoreDecodeCallback(callbackGeneration: 7, activeGeneration: 8))
        #expect(
            VideoDecoder.shouldIgnoreDecodeCallback(callbackGeneration: 8, activeGeneration: 8) == false
        )
    }
}
