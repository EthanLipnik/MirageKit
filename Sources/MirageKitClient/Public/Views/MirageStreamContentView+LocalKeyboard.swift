//
//  MirageStreamContentView+LocalKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Local Keyboard

extension MirageStreamContentView {
    #if os(iOS)
    func handleLocalKeyboardFrameChange(_ notification: Notification) {
        guard keyboardAvoidanceEnabled else {
            localKeyboardOcclusionActive = false
            return
        }

        guard let keyboardEndFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        let screenBounds: CGRect = if MirageClientService.lastKnownScreenPointSize.width > 0,
                                      MirageClientService.lastKnownScreenPointSize.height > 0 {
            CGRect(origin: .zero, size: MirageClientService.lastKnownScreenPointSize)
        } else {
            UIScreen.main.bounds
        }

        localKeyboardOcclusionActive = hasLocalKeyboardOcclusion(
            keyboardEndFrame: keyboardEndFrame,
            screenBounds: screenBounds,
            minimumOcclusionHeight: 120
        )
    }
    #endif
}
