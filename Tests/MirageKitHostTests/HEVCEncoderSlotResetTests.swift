//
//  HEVCEncoderSlotResetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Verifies encoder in-flight slot reset behavior used by recovery paths.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("HEVC Encoder Slot Reset")
struct HEVCEncoderSlotResetTests {
    @Test("Resetting slots clears saturation and restores admission")
    func resetSlotsClearsSaturation() {
        let encoder = HEVCEncoder(
            configuration: MirageEncoderConfiguration(
                targetFrameRate: 60,
                pixelFormat: .nv12
            ),
            latencyMode: .auto,
            inFlightLimit: 2
        )

        #expect(encoder.reserveEncoderSlot())
        #expect(encoder.reserveEncoderSlot())
        #expect(!encoder.reserveEncoderSlot())
        #expect(encoder.encoderInFlightSnapshot() == 2)

        encoder.resetEncoderSlots()
        #expect(encoder.encoderInFlightSnapshot() == 0)
        #expect(encoder.reserveEncoderSlot())
        #expect(encoder.reserveEncoderSlot())
        #expect(!encoder.reserveEncoderSlot())
    }
}
#endif
