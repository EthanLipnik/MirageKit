//
//  VideoEncoder+EncodedFrameExtraction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Encoded frame extraction and callback failure diagnostics.
//

import CoreMedia
import Foundation

#if os(macOS)
extension VideoEncoder {
    nonisolated static func extractEncodedFrameData(from dataBuffer: CMBlockBuffer) throws -> Data {
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { throw EncodedFrameExtractionError.emptyData }

        var contiguousLength = 0
        var totalLengthOut = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLengthOut,
            dataPointerOut: &dataPointer
        )

        if pointerStatus == noErr,
           totalLengthOut == totalLength,
           contiguousLength == totalLength,
           let dataPointer {
            return Data(bytes: dataPointer, count: totalLength)
        }

        var copiedData = Data(count: totalLength)
        let copyStatus = copiedData.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -12700 }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }

        guard copyStatus == noErr else {
            throw EncodedFrameExtractionError.copyFailed(
                status: copyStatus,
                totalLength: totalLength,
                pointerStatus: pointerStatus,
                contiguousLength: contiguousLength
            )
        }

        return copiedData
    }

    nonisolated func recordCallbackFailure(frameNumber: UInt64, status: OSStatus) {
        let count: UInt64
        let shouldLog: Bool
        bitstreamFailureLogLock.lock()
        do {
            defer { bitstreamFailureLogLock.unlock() }
            callbackFailureCount += 1
            count = callbackFailureCount
            let now = CFAbsoluteTimeGetCurrent()
            shouldLog = lastCallbackFailureLogTime == 0 ||
                now - lastCallbackFailureLogTime >= Self.bitstreamFailureLogCooldown
            if shouldLog { lastCallbackFailureLogTime = now }
        }

        if shouldLog {
            MirageLogger.error(
                .encoder,
                "Encoder callback failure: frame=\(frameNumber), status=\(status), totalFailures=\(count)"
            )
        }
    }

    nonisolated func consumeCallbackFailureCount() -> UInt64 {
        bitstreamFailureLogLock.lock()
        defer { bitstreamFailureLogLock.unlock() }
        let count = callbackFailureCount
        callbackFailureCount = 0
        return count
    }

    nonisolated func shouldLogBitstreamFailure(at now: CFAbsoluteTime) -> Bool {
        bitstreamFailureLogLock.lock()
        defer { bitstreamFailureLogLock.unlock() }
        if lastBitstreamFailureLogTime > 0,
           now - lastBitstreamFailureLogTime < Self.bitstreamFailureLogCooldown {
            return false
        }
        lastBitstreamFailureLogTime = now
        return true
    }
}

#endif
