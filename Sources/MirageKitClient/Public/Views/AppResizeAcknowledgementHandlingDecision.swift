//
//  AppResizeAcknowledgementHandlingDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import MirageKit
import CoreGraphics

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

enum AppStreamAspectFitPresentationDecision: Equatable {
    case fill
    case aspectFit
}

func appStreamAspectFitPresentationDecision(
    containerSize: CGSize,
    streamContentSize: CGSize?,
    aspectTolerance: CGFloat = 0.03
)
-> AppStreamAspectFitPresentationDecision {
    guard containerSize.width > 0,
          containerSize.height > 0,
          let streamContentSize,
          streamContentSize.width > 0,
          streamContentSize.height > 0 else {
        return .fill
    }

    let containerAspectRatio = containerSize.width / containerSize.height
    let streamAspectRatio = streamContentSize.width / streamContentSize.height
    let relativeDelta = abs(streamAspectRatio - containerAspectRatio) / max(0.001, containerAspectRatio)
    return relativeDelta > aspectTolerance ? .aspectFit : .fill
}
