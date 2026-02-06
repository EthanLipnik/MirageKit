//
//  FlippedView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(macOS)
import AppKit

/// A flipped NSView for correct coordinate system in scroll view
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
