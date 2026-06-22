//
//  LocalKeyboardOcclusion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//
//  Local keyboard occlusion helpers for client-side presentation-only resizing.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics

func hasLocalKeyboardOcclusion(
    keyboardFrame: CGRect,
    occlusionBounds: CGRect,
    minimumOcclusionHeight: CGFloat
) -> Bool {
    localKeyboardOcclusionHeight(
        keyboardFrame: keyboardFrame,
        occlusionBounds: occlusionBounds,
        minimumOcclusionHeight: minimumOcclusionHeight
    ) > 0
}

func localKeyboardOcclusionHeight(
    keyboardFrame: CGRect,
    occlusionBounds: CGRect,
    minimumOcclusionHeight: CGFloat
) -> CGFloat {
    guard keyboardFrame.width > 0,
          keyboardFrame.height > 0,
          occlusionBounds.width > 0,
          occlusionBounds.height > 0 else {
        return 0
    }

    let overlap = occlusionBounds.intersection(keyboardFrame)
    guard !overlap.isNull,
          !overlap.isEmpty,
          overlap.height >= minimumOcclusionHeight else {
        return 0
    }
    return overlap.height
}
