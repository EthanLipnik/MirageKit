//
//  AppAtlasMediaCoordinator+SourceRect.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

import CoreGraphics

#if os(macOS)
extension AppAtlasMediaCoordinator {
    nonisolated static func normalizedSourceRect(contentRect: CGRect, pixelSize: CGSize) -> CGRect {
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return .zero
        }

        let fullRect = CGRect(origin: .zero, size: pixelSize).integral
        let candidate = contentRect.standardized
        guard candidate.origin.x.isFinite,
              candidate.origin.y.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite,
              candidate.width > 0,
              candidate.height > 0 else {
            return fullRect
        }

        let clamped = candidate.integral.intersection(fullRect).standardized
        guard clamped.width > 0, clamped.height > 0 else {
            return fullRect
        }
        return clamped
    }
}
#endif
