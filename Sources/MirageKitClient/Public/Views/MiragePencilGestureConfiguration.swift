//
//  MiragePencilGestureConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Stores the client-side Apple Pencil gesture mapping for stream interactions.
public struct MiragePencilGestureConfiguration: Codable, Sendable, Hashable {
    /// Action performed for Apple Pencil double tap.
    public var doubleTap: MiragePencilGestureAction
    /// Action performed for Apple Pencil squeeze.
    public var squeeze: MiragePencilGestureAction

    /// Default mapping used for new client installs.
    public static let `default` = MiragePencilGestureConfiguration(
        doubleTap: .toggleDictation,
        squeeze: .secondaryClick
    )

    /// Creates a Pencil gesture mapping with optional overrides for each supported gesture.
    public init(
        doubleTap: MiragePencilGestureAction = .toggleDictation,
        squeeze: MiragePencilGestureAction = .secondaryClick
    ) {
        self.doubleTap = doubleTap
        self.squeeze = squeeze
    }

    /// Returns the configured action for a gesture.
    public func action(for kind: MiragePencilGestureKind) -> MiragePencilGestureAction {
        switch kind {
        case .doubleTap:
            doubleTap
        case .squeeze:
            squeeze
        }
    }

    /// Updates the configured action for a gesture.
    public mutating func setAction(
        _ action: MiragePencilGestureAction,
        for kind: MiragePencilGestureKind
    ) {
        switch kind {
        case .doubleTap:
            doubleTap = action
        case .squeeze:
            squeeze = action
        }
    }
}
