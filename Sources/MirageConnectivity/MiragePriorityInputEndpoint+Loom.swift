//
//  MiragePriorityInputEndpoint+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom

package protocol MiragePriorityInputEndpointProtocol: AnyObject, Sendable {
    func sendRealtime(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendRealtimeSequenced(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendContinuous(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendProtected(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func makeIncomingPayloadStream(maxBytes: Int) -> AsyncStream<Data>
}

package extension MiragePriorityInputEndpointProtocol {
    func sendRealtime(_ payload: Data) {
        sendRealtime(payload) { _ in }
    }

    func sendRealtimeSequenced(_ payload: Data) {
        sendRealtimeSequenced(payload) { _ in }
    }

    func sendContinuous(_ payload: Data) {
        sendContinuous(payload) { _ in }
    }

    func sendProtected(_ payload: Data) {
        sendProtected(payload) { _ in }
    }

    func makeIncomingPayloadStream() -> AsyncStream<Data> {
        makeIncomingPayloadStream(maxBytes: MiragePriorityInputEndpointLimits.maximumPayloadBytes)
    }
}

extension LoomPriorityInputEndpoint: MiragePriorityInputEndpointProtocol {}

package enum MiragePriorityInputEndpointLimits {
    package static let maximumPayloadBytes = LoomPriorityInputEndpoint.maximumPayloadBytes
}
