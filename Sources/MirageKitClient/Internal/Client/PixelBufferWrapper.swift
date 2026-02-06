//
//  PixelBufferWrapper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

/// Wrapper to safely send CVPixelBuffer across isolation boundaries
/// CVPixelBuffer is a Core Foundation type that's inherently thread-safe
struct PixelBufferWrapper: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
    let contentRect: CGRect
}
