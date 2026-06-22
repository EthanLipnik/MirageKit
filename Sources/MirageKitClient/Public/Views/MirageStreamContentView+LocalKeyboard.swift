//
//  MirageStreamContentView+LocalKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Local Keyboard

extension MirageStreamContentView {
    #if os(iOS)
    func handleLocalKeyboardOcclusionDetectionChanged(_ occlusionHeight: CGFloat) {
        let normalizedOcclusionHeight = max(0, occlusionHeight)
        let isOccluded = normalizedOcclusionHeight > 0
        localKeyboardOcclusionClearTask?.cancel()
        localKeyboardOcclusionClearTask = nil
        if abs(localKeyboardOcclusionHeight - normalizedOcclusionHeight) >= 0.5 {
            localKeyboardOcclusionHeight = normalizedOcclusionHeight
        }
        if isOccluded {
            if !localKeyboardOcclusionActive {
                localKeyboardOcclusionActive = true
            }
        } else if localKeyboardOcclusionActive {
            localKeyboardOcclusionClearTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                localKeyboardOcclusionActive = false
                localKeyboardOcclusionClearTask = nil
            }
        }
    }
    #endif
}
