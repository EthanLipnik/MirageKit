//
//  DesktopResizeStartupDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/6/26.
//

enum DesktopResizeStartupDecision: Equatable {
    case deferUntilFirstPresentation
    case allowResizeFlow
}

func desktopResizeStartupDecision(hasPresentedFrame: Bool) -> DesktopResizeStartupDecision {
    if hasPresentedFrame {
        return .allowResizeFlow
    }
    return .deferUntilFirstPresentation
}
