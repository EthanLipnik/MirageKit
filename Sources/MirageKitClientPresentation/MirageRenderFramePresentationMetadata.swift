//
//  MirageRenderFramePresentationMetadata.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreGraphics
import CoreVideo

/// Pixel-buffer presentation metadata normalized for client render surfaces.
package struct MirageRenderFramePresentationMetadata: Equatable {
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let pixelFormat: OSType
    package let contentReferenceSize: CGSize
    package let normalizedContentRect: CGRect

    package init(pixelBuffer: CVPixelBuffer, contentRect: CGRect) {
        pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let resolvedContentRect: CGRect
        if contentRect.width > 0, contentRect.height > 0 {
            resolvedContentRect = contentRect
        } else {
            resolvedContentRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        contentReferenceSize = resolvedContentRect.size

        guard width > 0, height > 0 else {
            normalizedContentRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        normalizedContentRect = CGRect(
            x: min(max(resolvedContentRect.origin.x / width, 0), 1),
            y: min(max(resolvedContentRect.origin.y / height, 0), 1),
            width: min(max(resolvedContentRect.size.width / width, 0), 1),
            height: min(max(resolvedContentRect.size.height / height, 0), 1)
        )
    }
}
