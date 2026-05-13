//
//  VideoDecoder+ProResFormat.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

extension VideoDecoder {
    /// Creates or refreshes a ProRes 4444 format description and returns the original frame data.
    func extractProResFormatDescription(from data: Data) throws -> Data {
        let dims: (width: Int, height: Int)? =
            proResFrameDimensions(from: data) ?? expectedDimensions ?? proResStreamDimensions
        let needsNewDescription: Bool
        if let dims {
            if let existing = formatDescription {
                let existingDims = CMVideoFormatDescriptionGetDimensions(existing)
                needsNewDescription = Int32(dims.width) != existingDims.width || Int32(dims.height) != existingDims.height
            } else {
                needsNewDescription = true
            }
        } else {
            needsNewDescription = false
        }
        if needsNewDescription, let dims {
            let colorExtensions = MirageColorAttachments.formatDescriptionExtensions(
                for: preferredOutputColorDepth.colorSpace
            )

            var formatDesc: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AppleProRes4444,
                width: Int32(dims.width),
                height: Int32(dims.height),
                extensions: colorExtensions,
                formatDescriptionOut: &formatDesc
            )
            if status == noErr, let desc = formatDesc {
                formatDescription = desc
                cachedFormatDescription = desc
                outputPixelFormat = preferredOutputPixelFormat(for: preferredOutputColorDepth)
                MirageLogger.decoder("ProRes 4444 format description created (\(dims.width)x\(dims.height))")
            } else {
                MirageLogger.error(.decoder, "Failed to create ProRes format description: \(status)")
            }
        }
        return data
    }

    /// Extracts width and height from the ProRes picture header.
    func proResFrameDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 20 else { return nil }
        let width = Int(data[16]) << 8 | Int(data[17])
        let height = Int(data[18]) << 8 | Int(data[19])
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }
        return (width: width, height: height)
    }
}
