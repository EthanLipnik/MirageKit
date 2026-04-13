//
//  DesktopResizeStartAcknowledgementHandlingDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

import MirageKit

func isMeaningfulAppResizeAcknowledgement(
    _ latest: MirageClientService.StreamStartAcknowledgement?,
    comparedTo baseline: MirageClientService.StreamStartAcknowledgement?
) -> Bool {
    guard let latest else { return false }
    guard let baseline else {
        return latest.width > 0 && latest.height > 0
    }
    if let latestToken = latest.dimensionToken,
       let baselineToken = baseline.dimensionToken,
       latestToken != baselineToken {
        return true
    }
    return latest.width != baseline.width || latest.height != baseline.height
}

enum AppStreamStartAcknowledgementHandlingDecision: Equatable {
    case ignore
    case recheckMinimumSize
}

func appStreamStartAcknowledgementHandlingDecision(
    awaitingResizeAcknowledgement: Bool,
    latest: MirageClientService.StreamStartAcknowledgement?,
    baseline: MirageClientService.StreamStartAcknowledgement?
)
-> AppStreamStartAcknowledgementHandlingDecision {
    guard awaitingResizeAcknowledgement,
          isMeaningfulAppResizeAcknowledgement(latest, comparedTo: baseline) else {
        return .ignore
    }
    return .recheckMinimumSize
}

enum DesktopResizeStartAcknowledgementHandlingDecision: Equatable {
    case ignore
    case waitForResizeAdvance
    case beginConvergenceCheck
    case continueConvergenceCheck
}

func desktopResizeStartAcknowledgementHandlingDecision(
    awaitingResizeAcknowledgement: Bool,
    acknowledgementProgressStarted: Bool,
    latest: MirageClientService.StreamStartAcknowledgement?,
    baseline: MirageClientService.StreamStartAcknowledgement?
)
-> DesktopResizeStartAcknowledgementHandlingDecision {
    guard awaitingResizeAcknowledgement else { return .ignore }

    guard let latest else {
        return acknowledgementProgressStarted ? .continueConvergenceCheck : .waitForResizeAdvance
    }

    guard let baseline else {
        if acknowledgementProgressStarted {
            return .continueConvergenceCheck
        }
        return isMeaningfulAppResizeAcknowledgement(latest, comparedTo: nil)
            ? .beginConvergenceCheck
            : .waitForResizeAdvance
    }

    if let baselineToken = baseline.dimensionToken {
        guard let latestToken = latest.dimensionToken else {
            return acknowledgementProgressStarted ? .continueConvergenceCheck : .waitForResizeAdvance
        }
        if latestToken < baselineToken { return .ignore }
        if latestToken == baselineToken {
            return acknowledgementProgressStarted ? .continueConvergenceCheck : .waitForResizeAdvance
        }
        return acknowledgementProgressStarted ? .continueConvergenceCheck : .beginConvergenceCheck
    }

    if acknowledgementProgressStarted {
        return .continueConvergenceCheck
    }

    return isMeaningfulAppResizeAcknowledgement(latest, comparedTo: baseline)
        ? .beginConvergenceCheck
        : .waitForResizeAdvance
}
