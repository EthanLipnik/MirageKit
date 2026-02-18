//
//  MirageRenderFrame.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Stream-local frame snapshot for decode-to-render handoff.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MirageKit

struct MirageRenderFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
    let sequence: UInt64
    let decodeTime: CFAbsoluteTime
    let presentationTime: CMTime
    let metalTexture: CVMetalTexture?
    let texture: MTLTexture?
}
