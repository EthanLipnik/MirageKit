//
//  StreamControllerMosaicDependencyStateTests.swift
//  MirageKitClient
//
//  Created by Ethan Lipnik on 6/7/26.
//

import CoreMedia
import Foundation
@testable import MirageKitClient
import Testing

@Suite("StreamController Mosaic Dependency State")
struct StreamControllerMosaicDependencyStateTests {
    @Test("Mosaic dependency recovery uses decode recovery")
    func mosaicDependencyRecoveryUsesDecodeRecovery() {
        #expect(Self.recoveryCause(for: .decodeErrorThreshold) == .decodeError)
        #expect(Self.recoveryCause(for: .dependencyMissing) == .decodeError)
        #expect(Self.recoveryCause(for: .dependencyMismatch) == .decodeError)
        #expect(Self.recoveryCause(for: .decodeSubmissionFailure) == .decodeError)
    }

    @Test("P-units require a decoded matching tile dependency")
    func pUnitsRequireDecodedMatchingTileDependency() {
        let state = StreamControllerMosaicDependencyState()
        let keyframe = Self.unit(
            isKeyframe: true,
            tileVersion: 4,
            dependencyVersion: 0
        )
        let matchingPFrame = Self.unit(
            isKeyframe: false,
            tileVersion: 5,
            dependencyVersion: 4
        )
        let mismatchedPFrame = Self.unit(
            isKeyframe: false,
            tileVersion: 6,
            dependencyVersion: 3
        )

        #expect(state.validate(matchingPFrame) == .missingDependency)
        #expect(state.validate(keyframe) == .accepted)
        state.noteSubmitted(
            keyframe,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )
        #expect(state.validate(matchingPFrame) == .missingDependency)

        state.noteDecoded(
            mediaUnitIndex: keyframe.mediaUnitIndex,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )
        #expect(state.validate(matchingPFrame) == .accepted)
        #expect(state.validate(mismatchedPFrame) == .dependencyMismatch(
            retainedVersion: 4,
            expectedVersion: 3
        ))
    }

    @Test("Older Mosaic units are stale drops, not recovery")
    func olderMosaicUnitsAreStaleDropsNotRecovery() {
        let state = StreamControllerMosaicDependencyState()
        let keyframe = Self.unit(
            isKeyframe: true,
            tileVersion: 4,
            dependencyVersion: 0
        )
        state.noteSubmitted(
            keyframe,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )
        state.noteDecoded(
            mediaUnitIndex: keyframe.mediaUnitIndex,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )

        let staleUnit = Self.unit(
            isKeyframe: false,
            tileVersion: 4,
            dependencyVersion: 4
        )
        #expect(state.validate(staleUnit) == .stale(retainedVersion: 4, tileVersion: 4))
    }

    @Test("Plan epoch changes clear retained dependencies")
    func planEpochChangesClearRetainedDependencies() {
        let state = StreamControllerMosaicDependencyState()
        let keyframe = Self.unit(
            tilePlanEpoch: 2,
            isKeyframe: true,
            tileVersion: 7,
            dependencyVersion: 0
        )
        state.noteSubmitted(
            keyframe,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )
        state.noteDecoded(
            mediaUnitIndex: keyframe.mediaUnitIndex,
            presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
        )

        let nextPlanPFrame = Self.unit(
            tilePlanEpoch: 3,
            isKeyframe: false,
            tileVersion: 8,
            dependencyVersion: 7
        )
        #expect(state.validate(nextPlanPFrame) == .missingDependency)
    }

    @Test("Per-unit reset preserves other retained dependencies")
    func perUnitResetPreservesOtherRetainedDependencies() {
        let state = StreamControllerMosaicDependencyState()
        let firstKeyframe = Self.unit(
            mediaUnitIndex: 4,
            isKeyframe: true,
            tileVersion: 4,
            dependencyVersion: 0
        )
        let secondKeyframe = Self.unit(
            mediaUnitIndex: 5,
            isKeyframe: true,
            tileVersion: 9,
            dependencyVersion: 0
        )
        for keyframe in [firstKeyframe, secondKeyframe] {
            state.noteSubmitted(
                keyframe,
                presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
            )
            state.noteDecoded(
                mediaUnitIndex: keyframe.mediaUnitIndex,
                presentationTime: CMTime(value: Int64(keyframe.mediaEpoch), timescale: 60)
            )
        }

        state.reset(mediaUnitIndex: firstKeyframe.mediaUnitIndex)

        #expect(state.validate(Self.unit(
            mediaUnitIndex: 4,
            isKeyframe: false,
            tileVersion: 5,
            dependencyVersion: 4
        )) == .missingDependency)
        #expect(state.validate(Self.unit(
            mediaUnitIndex: 5,
            isKeyframe: false,
            tileVersion: 10,
            dependencyVersion: 9
        )) == .accepted)
    }

    private static func unit(
        tilePlanEpoch: UInt32 = 2,
        mediaUnitIndex: UInt16 = 4,
        isKeyframe: Bool,
        tileVersion: UInt32,
        dependencyVersion: UInt32
    ) -> StreamControllerMosaicMediaUnitReassembler.CompletedUnit {
        StreamControllerMosaicMediaUnitReassembler.CompletedUnit(
            streamID: 55,
            timestamp: 1,
            tilePlanEpoch: tilePlanEpoch,
            mediaEpoch: 10,
            mediaUnitIndex: mediaUnitIndex,
            tileIndex: mediaUnitIndex,
            transportGroupIndex: 0,
            presentationGroupIndex: 0,
            unitFrameNumber: 20,
            tileVersion: tileVersion,
            dependencyVersion: dependencyVersion,
            isKeyframe: isKeyframe,
            isAtomicGroup: true,
            payload: Data([0x01])
        )
    }

    private static func recoveryCause(
        for trigger: StreamControllerMosaicClientPipeline.RecoveryTrigger
    ) -> MirageStreamClientRecoveryCause {
        MirageClientService.streamRecoveryReason(forMosaicTrigger: trigger).recoveryCause
    }
}
