//
//  QualityTestPayloadTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

#if os(macOS)
import Foundation
@testable import MirageKitHost
import Testing

@Suite("Quality Test Payload")
struct QualityTestPayloadTests {
    @Test("Quality test payload is deterministic non-zero data")
    func qualityTestPayloadIsDeterministicNonZeroData() throws {
        let testID = try #require(UUID(uuidString: "4E1E79CA-11AB-4D7C-9B2B-8A03B64A9001"))

        let first = MirageHostService.qualityTestPayload(
            testID: testID,
            stageID: 1,
            payloadBytes: 256
        )
        let repeated = MirageHostService.qualityTestPayload(
            testID: testID,
            stageID: 1,
            payloadBytes: 256
        )
        let differentStage = MirageHostService.qualityTestPayload(
            testID: testID,
            stageID: 2,
            payloadBytes: 256
        )

        #expect(first.count == 256)
        #expect(first == repeated)
        #expect(first != differentStage)
        #expect(first.contains { $0 != 0 })
    }
}
#endif
