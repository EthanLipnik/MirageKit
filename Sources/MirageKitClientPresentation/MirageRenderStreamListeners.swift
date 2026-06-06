//
//  MirageRenderStreamListeners.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import Foundation

/// Weak owner token used to drop render-frame listeners after their owner deallocates.
package final class MirageRenderStreamWeakOwner {
    package private(set) weak var value: AnyObject?

    package init(_ value: AnyObject) {
        self.value = value
    }
}

package struct MirageRenderStreamFrameListener {
    /// Weak owner that controls listener lifetime.
    package let owner: MirageRenderStreamWeakOwner

    /// Callback invoked when the store has work for the listener.
    package let callback: @Sendable () -> Void

    package init(
        owner: MirageRenderStreamWeakOwner,
        callback: @escaping @Sendable () -> Void
    ) {
        self.owner = owner
        self.callback = callback
    }
}
