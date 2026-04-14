//
//  DesktopStreamStartFailureDisposition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import MirageKit

enum DesktopStreamStartFailureDisposition: Equatable {
    case noChange
    case clearPendingStart
}

func desktopStreamStartFailureDisposition(
    errorCode: ErrorMessage.ErrorCode,
    desktopStartPending: Bool,
    hasActiveDesktopStream: Bool
) -> DesktopStreamStartFailureDisposition {
    guard desktopStartPending else { return .noChange }
    guard !hasActiveDesktopStream else { return .noChange }
    _ = errorCode
    return .clearPendingStart
}

@MainActor
extension MirageClientService {
    func clearPendingDesktopStreamStartState() {
        guard desktopStreamID == nil else { return }
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = nil
        desktopStreamRequestStartTime = 0
        desktopStreamMode = nil
        desktopCursorPresentation = nil
        pendingDesktopRequestedColorDepth = nil
        desktopResizeCoordinator.clearAllState()
    }
}
