//
//  MessageTypes+CustomStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CoreVideo

// MARK: - Custom Streaming Messages

package extension MirageWire.StartCustomStreamMessage {
    /// Public request handed to custom stream providers.
    var publicRequest: MirageCustomStreamRequest {
        MirageCustomStreamRequest(
            requestID: startupRequestID,
            kind: kind,
            metadata: metadata,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            targetFrameRate: targetFrameRate,
            requiredPixelFormat: kCVPixelFormatType_32BGRA
        )
    }
}
