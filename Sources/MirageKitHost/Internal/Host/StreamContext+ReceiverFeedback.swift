//
//  StreamContext+ReceiverFeedback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Receiver media feedback telemetry.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func recordReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) async {
        guard feedback.streamID == streamID else { return }
        realtimeMediaSession.recordFeedback(feedback)
    }
}
#endif
