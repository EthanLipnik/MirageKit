//
//  MirageQueuedUnreliableMediaStream+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageMedia

package protocol MirageQueuedUnreliableMediaStream: Sendable {
    func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        options: MirageQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func resetQueuedUnreliableSends(profile: MirageMedia.MirageMediaSendProfile) async

    func mirageQueuedUnreliableSendDiagnostics(
        profile: MirageMedia.MirageMediaSendProfile
    ) async -> MirageQueuedUnreliableSendDiagnostics?

    func close() async throws
}

extension LoomMultiplexedStream: MirageQueuedUnreliableMediaStream {
    package func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        sendUnreliableQueued(
            data,
            profile: MirageConnectivityLoomAdapter.loomMediaSendProfile(from: profile),
            onComplete: onComplete
        )
    }

    package func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        options: MirageQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        sendUnreliableQueued(
            data,
            profile: MirageConnectivityLoomAdapter.loomMediaSendProfile(from: profile),
            options: LoomQueuedUnreliableSendOptions(mirageOptions: options),
            onComplete: onComplete
        )
    }

    package func resetQueuedUnreliableSends(profile: MirageMedia.MirageMediaSendProfile) async {
        await resetQueuedUnreliableSends(
            profile: MirageConnectivityLoomAdapter.loomMediaSendProfile(from: profile)
        )
    }
}

package extension MirageMedia.MirageMediaSendProfile {
    init(loomProfile profile: LoomQueuedUnreliableSendProfile) {
        self = MirageConnectivityLoomAdapter.mediaSendProfile(from: profile)
    }
}
