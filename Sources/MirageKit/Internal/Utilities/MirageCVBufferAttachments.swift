//
//  MirageCVBufferAttachments.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreVideo
import Foundation

/// Helpers for reading Core Video attachment metadata shared by host capture and client presentation.
package enum MirageCVBufferAttachments {
    /// Returns the attachment value as a Swift string when Core Video exposes it as string metadata.
    package static func string(_ buffer: CVBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    /// Sets an attachment only when the buffer does not already carry the requested value.
    package static func setIfNeeded(
        _ buffer: CVBuffer,
        key: CFString,
        value: CFTypeRef,
        mode: CVAttachmentMode = .shouldPropagate
    ) {
        if let existing = CVBufferCopyAttachment(buffer, key, nil), CFEqual(existing, value) {
            return
        }
        CVBufferSetAttachment(buffer, key, value, mode)
    }
}
