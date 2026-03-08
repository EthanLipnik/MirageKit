//
//  HEVCDecoderSessionRecreationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/7/26.
//

@testable import MirageKitClient
import Testing

@Suite("HEVC Decoder Session Recreation")
struct HEVCDecoderSessionRecreationTests {
    @Test("Parameter-set changes recreate the decoder session even when dimensions stay constant")
    func parameterSetChangesTriggerSessionRecreation() {
        #expect(HEVCDecoder.shouldRecreateSession(
            isFirstKeyframe: false,
            dimensionsChanged: false,
            parameterSetsChanged: true,
            shouldRecreateForErrors: false
        ))
    }

    @Test("First keyframe does not count as a format-change recreation")
    func firstKeyframeDoesNotForceRecreation() {
        #expect(!HEVCDecoder.shouldRecreateSession(
            isFirstKeyframe: true,
            dimensionsChanged: false,
            parameterSetsChanged: true,
            shouldRecreateForErrors: false
        ))
    }
}
