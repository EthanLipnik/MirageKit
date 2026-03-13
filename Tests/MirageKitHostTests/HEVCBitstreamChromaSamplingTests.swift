//
//  HEVCBitstreamChromaSamplingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("HEVC Bitstream Chroma Sampling")
struct HEVCBitstreamChromaSamplingTests {
    @Test("SPS parser detects 4:2:0 chroma")
    func parses420ChromaSampling() {
        #expect(HEVCEncoder.hevcChromaSampling(fromSPS: makeSyntheticSPS(chromaFormatIDC: 1)) == .yuv420)
    }

    @Test("SPS parser detects 4:2:2 chroma")
    func parses422ChromaSampling() {
        #expect(HEVCEncoder.hevcChromaSampling(fromSPS: makeSyntheticSPS(chromaFormatIDC: 2)) == .yuv422)
    }

    @Test("SPS parser detects 4:4:4 chroma")
    func parses444ChromaSampling() {
        #expect(HEVCEncoder.hevcChromaSampling(fromSPS: makeSyntheticSPS(chromaFormatIDC: 3)) == .yuv444)
    }

    @Test("Ultra encode path does not force a legacy HEVC profile")
    func ultraProfileSelectionUsesAutomaticMode() {
        #expect(HEVCEncoder.requestedProfileLevels(for: .xf44).isEmpty)
    }

    private func makeSyntheticSPS(chromaFormatIDC: Int) -> Data {
        var bits: [Bool] = []

        appendBits(value: 0, count: 4, into: &bits) // sps_video_parameter_set_id
        appendBits(value: 0, count: 3, into: &bits) // sps_max_sub_layers_minus1
        appendBits(value: 1, count: 1, into: &bits) // sps_temporal_id_nesting_flag

        appendBits(value: 0, count: 2, into: &bits) // general_profile_space
        appendBits(value: 0, count: 1, into: &bits) // general_tier_flag
        appendBits(value: 1, count: 5, into: &bits) // general_profile_idc
        appendBits(value: 0, count: 32, into: &bits) // general_profile_compatibility_flags
        appendBits(value: 0, count: 48, into: &bits) // general_constraint_indicator_flags
        appendBits(value: 120, count: 8, into: &bits) // general_level_idc

        appendUnsignedExpGolomb(0, into: &bits) // sps_seq_parameter_set_id
        appendUnsignedExpGolomb(chromaFormatIDC, into: &bits) // chroma_format_idc

        let payload = pack(bits: bits)
        return Data([0x42, 0x01]) + payload
    }

    private func appendUnsignedExpGolomb(_ value: Int, into bits: inout [Bool]) {
        let codeNum = max(0, value) + 1
        let bitWidth = max(1, Int.bitWidth - codeNum.leadingZeroBitCount)
        bits.append(contentsOf: Array(repeating: false, count: bitWidth - 1))
        appendBits(value: UInt64(codeNum), count: bitWidth, into: &bits)
    }

    private func appendBits(value: UInt64, count: Int, into bits: inout [Bool]) {
        guard count > 0 else { return }
        for bitIndex in stride(from: count - 1, through: 0, by: -1) {
            let bit = ((value >> UInt64(bitIndex)) & 0x01) == 1
            bits.append(bit)
        }
    }

    private func pack(bits: [Bool]) -> Data {
        guard !bits.isEmpty else { return Data() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity((bits.count + 7) / 8)

        var byte: UInt8 = 0
        for (index, bit) in bits.enumerated() {
            if bit {
                byte |= UInt8(1 << (7 - (index % 8)))
            }
            if index % 8 == 7 {
                bytes.append(byte)
                byte = 0
            }
        }

        if bits.count % 8 != 0 {
            bytes.append(byte)
        }

        return Data(bytes)
    }
}
#endif
