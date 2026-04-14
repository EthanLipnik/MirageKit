//
//  AppResizeAcknowledgementHandlingDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
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
