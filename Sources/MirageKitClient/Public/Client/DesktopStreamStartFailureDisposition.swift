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

    switch errorCode {
    case .virtualDisplayStartFailed,
         .sessionLocked,
         .waitingForHostApproval:
        return .clearPendingStart
    default:
        return .noChange
    }
}

@MainActor
extension MirageClientService {
    func clearPendingDesktopStreamStartState() {
        guard desktopStreamID == nil else { return }
        desktopStreamRequestStartTime = 0
        desktopStreamMode = nil
        pendingDesktopAdaptiveFallbackBitrate = nil
        pendingDesktopAdaptiveFallbackColorDepth = nil
    }
}
