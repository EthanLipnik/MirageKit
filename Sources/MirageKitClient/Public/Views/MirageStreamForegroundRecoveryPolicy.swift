//
//  MirageStreamForegroundRecoveryPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import Foundation
import SwiftUI

enum MirageStreamForegroundRecoverySwiftUIScenePhase: Equatable {
    case active
    case inactive
    case background
    case unknown

    init(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .unknown
        }
    }

    var logLabel: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        case .unknown:
            "unknown"
        }
    }
}

enum MirageStreamForegroundRecoveryDecision: Equatable {
    case dispatch(swiftUIScenePhase: MirageStreamForegroundRecoverySwiftUIScenePhase)
    case deferUntilControllerAvailable(swiftUIScenePhase: MirageStreamForegroundRecoverySwiftUIScenePhase)
    case skipInactiveDesktopStream
    case skipBeforeFirstFrame(desktopSessionID: UUID)
}

enum MirageStreamForegroundRecoveryPolicy {
    static func decisionForInputCaptureApplicationActivation(
        swiftUIScenePhase: MirageStreamForegroundRecoverySwiftUIScenePhase,
        isDesktopStream: Bool,
        activeDesktopSessionID: UUID?,
        hasPresentedFrame: Bool,
        hasController: Bool
    ) -> MirageStreamForegroundRecoveryDecision {
        if isDesktopStream {
            guard let activeDesktopSessionID else {
                return .skipInactiveDesktopStream
            }
            guard hasPresentedFrame else {
                return .skipBeforeFirstFrame(desktopSessionID: activeDesktopSessionID)
            }
        }

        guard hasController else {
            return .deferUntilControllerAvailable(swiftUIScenePhase: swiftUIScenePhase)
        }
        return .dispatch(swiftUIScenePhase: swiftUIScenePhase)
    }
}
