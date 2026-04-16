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
    keyboardEndFrame: CGRect,
    screenBounds: CGRect,
    minimumOcclusionHeight: CGFloat
) -> Bool {
    guard keyboardEndFrame.width > 0,
          keyboardEndFrame.height > 0,
          screenBounds.width > 0,
          screenBounds.height > 0 else {
        return false
    }

    let overlap = screenBounds.intersection(keyboardEndFrame)
    guard !overlap.isNull, !overlap.isEmpty else { return false }
    return overlap.height >= minimumOcclusionHeight
}
