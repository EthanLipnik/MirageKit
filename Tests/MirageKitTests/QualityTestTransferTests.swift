//
//  QualityTestTransferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
//

import Foundation
@testable import MirageKit
import Testing
import MirageWire

@Suite("Quality Test Request")
struct QualityTestTransferTests {
    @Test("Quality test request requires transfer byte count")
    func requestRequiresTransferByteCount() throws {
        let testID = try #require(UUID(uuidString: "6B22D564-8B1D-4BE3-8AF3-DF48118631E7"))
        let payload = """
        {
          "testID": "\(testID.uuidString)",
          "plan": { "stages": [] },
          "payloadBytes": 1200,
          "mediaMaxPacketSize": 1400,
          "stopAfterFirstBreach": false
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MirageWire.QualityTestRequestMessage.self, from: payload)
        }
    }
}
