//
//  LocalKeyboardOcclusion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//
//  Local keyboard occlusion helpers for client-side presentation-only resizing.
//

import CoreGraphics

func hasLocalKeyboardOcclusion(
    keyboardFrame: CGRect,
    occlusionBounds: CGRect,
    minimumOcclusionHeight: CGFloat
) -> Bool {
    guard keyboardFrame.width > 0,
          keyboardFrame.height > 0,
          occlusionBounds.width > 0,
          occlusionBounds.height > 0 else {
        return false
    }

    let overlap = occlusionBounds.intersection(keyboardFrame)
    guard !overlap.isNull, !overlap.isEmpty else { return false }
    return overlap.height >= minimumOcclusionHeight
}
