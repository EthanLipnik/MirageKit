//
//  VideoEncoderBitstreamValidationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Coverage for host AVCC validation and encoded-frame byte extraction.
//

@testable import MirageKitHost
import CoreMedia
import Foundation
import Testing

#if os(macOS)
@Suite("HEVC Encoder Bitstream Validation")
struct VideoEncoderBitstreamValidationTests {
    @Test("Valid multi-NAL AVCC payload passes validation")
    func validMultiNALPayloadPassesValidation() {
        let payload = makeLengthPrefixedPayload(nalUnits: [
            [0x26, 0x01, 0xAA, 0xBB],
            [0x02, 0x03, 0x04],
            [0x10],
        ])

        let result = VideoEncoder.validateLengthPrefixedHEVCBitstream(payload)
        #expect(result == .valid)
    }

    @Test("Malformed AVCC length overrun fails validation")
    func malformedLengthOverrunFailsValidation() {
        let payload = Data([0x00, 0x00, 0x00, 0x20, 0x11, 0x22, 0x33])
        let result = VideoEncoder.validateLengthPrefixedHEVCBitstream(payload)

        switch result {
        case let .truncatedNAL(offset, declaredLength, availableBytes):
            #expect(offset == 0)
            #expect(declaredLength == 32)
            #expect(availableBytes == 3)
        default:
            Issue.record("Expected truncated NAL validation result, got \(result)")
        }
    }

    @Test("Truncated AVCC payload fails validation")
    func truncatedPayloadFailsValidation() {
        var payload = makeLengthPrefixedPayload(nalUnits: [
            [0x01, 0x02, 0x03],
            [0x04, 0x05, 0x06],
        ])
        payload.removeLast()

        let result = VideoEncoder.validateLengthPrefixedHEVCBitstream(payload)
        switch result {
        case .truncatedNAL:
            break
        default:
            Issue.record("Expected truncated NAL validation result, got \(result)")
        }
    }

    @Test("Contiguous block-buffer extraction returns original bytes")
    func contiguousBlockBufferExtractionReturnsOriginalBytes() throws {
        let payload = makeLengthPrefixedPayload(nalUnits: [
            [0xAA, 0xBB, 0xCC, 0xDD],
            [0x11, 0x22],
        ])
        let blockBuffer = try makeBlockBuffer(from: payload)

        let extracted = try VideoEncoder.extractEncodedFrameData(from: blockBuffer)
        #expect(extracted == payload)
    }

    @Test("Non-contiguous block-buffer extraction copies full payload")
    func nonContiguousBlockBufferExtractionCopiesFullPayload() throws {
        let partA = makeLengthPrefixedPayload(nalUnits: [[0x01, 0x02, 0x03]])
        let partB = makeLengthPrefixedPayload(nalUnits: [[0xAA, 0xBB, 0xCC, 0xDD, 0xEE]])
        let expected = partA + partB

        let blockBuffer = try makeNonContiguousBlockBuffer(parts: [partA, partB])
        let extracted = try VideoEncoder.extractEncodedFrameData(from: blockBuffer)
        #expect(extracted == expected)
    }

    @Test("Empty block-buffer extraction throws empty-data error")
    func emptyBlockBufferExtractionThrows() throws {
        var emptyBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &emptyBuffer
        )
        #expect(status == noErr)
        guard status == noErr, let emptyBuffer else {
            Issue.record("Failed to create empty block buffer: \(status)")
            return
        }

        do {
            try VideoEncoder.extractEncodedFrameData(from: emptyBuffer)
            Issue.record("Expected empty-data extraction error")
        } catch let error as EncodedFrameExtractionError {
            #expect(error == .emptyData)
        } catch {
            Issue.record("Unexpected extraction error: \(error)")
        }
    }

    private func makeLengthPrefixedPayload(nalUnits: [[UInt8]]) -> Data {
        var payload = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: nal)
        }
        return payload
    }

    private func makeBlockBuffer(from data: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }

        let copyStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-50) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus))
        }
        return blockBuffer
    }

    private func makeNonContiguousBlockBuffer(parts: [Data]) throws -> CMBlockBuffer {
        var parent: CMBlockBuffer?
        let emptyStatus = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: UInt32(parts.count),
            flags: 0,
            blockBufferOut: &parent
        )
        guard emptyStatus == noErr, let parent else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(emptyStatus))
        }

        for part in parts {
            let segment = try makeBlockBuffer(from: part)
            let appendStatus = CMBlockBufferAppendBufferReference(
                parent,
                targetBBuf: segment,
                offsetToData: 0,
                dataLength: CMBlockBufferGetDataLength(segment),
                flags: 0
            )
            guard appendStatus == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(appendStatus))
            }
        }

        return parent
    }
}
#endif
