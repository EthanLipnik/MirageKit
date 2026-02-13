//
//  MessageTypes+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Control messages for quality testing.
//

import Foundation

package struct QualityTestRequestMessage: Codable {
    package let testID: UUID
    package let plan: MirageQualityTestPlan
    package let payloadBytes: Int

    package init(testID: UUID, plan: MirageQualityTestPlan, payloadBytes: Int) {
        self.testID = testID
        self.plan = plan
        self.payloadBytes = payloadBytes
    }
}

package struct QualityTestResultMessage: Codable {
    package let testID: UUID
    package let benchmarkWidth: Int
    package let benchmarkHeight: Int
    package let benchmarkFrameRate: Int
    package let encodeMs: Double?
    package let benchmarkVersion: Int

    package init(
        testID: UUID,
        benchmarkWidth: Int,
        benchmarkHeight: Int,
        benchmarkFrameRate: Int,
        encodeMs: Double?,
        benchmarkVersion: Int
    ) {
        self.testID = testID
        self.benchmarkWidth = benchmarkWidth
        self.benchmarkHeight = benchmarkHeight
        self.benchmarkFrameRate = benchmarkFrameRate
        self.encodeMs = encodeMs
        self.benchmarkVersion = benchmarkVersion
    }
}
