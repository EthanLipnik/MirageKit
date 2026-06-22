//
//  AppResizeAcknowledgementHandlingDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
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
