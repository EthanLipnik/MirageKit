//
//  CaptureStreamOutput+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Audio sample extraction for ScreenCaptureKit capture output.
//

import CoreMedia
import Foundation

#if os(macOS)
import AudioToolbox

extension CaptureStreamOutput {
    func emitAudio(sampleBuffer: CMSampleBuffer) {
        let audioHandler = currentAudioHandler
        guard let audioHandler else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        var bufferListSizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSizeNeeded > 0 else { return }

        let bufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            bufferListStorage.deallocate()
        }
        let bufferList = bufferListStorage.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalBytes = 0
        for buffer in buffers {
            totalBytes += Int(buffer.mDataByteSize)
        }
        guard totalBytes > 0 else { return }

        var pcmData = Data(capacity: totalBytes)
        for buffer in buffers {
            guard let source = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            pcmData.append(source.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        guard !pcmData.isEmpty else { return }

        let asbd = asbdPointer.pointee
        let captured = CapturedAudioBuffer(
            data: pcmData,
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            frameCount: max(0, CMSampleBufferGetNumSamples(sampleBuffer)),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        audioHandler(captured)
    }

    /// Current audio delivery closure protected by the capture-output audio lock.
    var currentAudioHandler: (@Sendable (CapturedAudioBuffer) -> Void)? {
        audioHandlerLock.lock()
        defer { audioHandlerLock.unlock() }
        return onAudio
    }
}
#endif
