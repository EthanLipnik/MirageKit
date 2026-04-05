//
//  MiragePencilGestureConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Stores the client-side Apple Pencil gesture mapping for stream interactions.
public struct MiragePencilGestureConfiguration: Codable, Sendable, Hashable {
    public var doubleTap: MiragePencilGestureAction
    public var squeeze: MiragePencilGestureAction

    public static let `default` = MiragePencilGestureConfiguration(
        doubleTap: .toggleDictation,
        squeeze: .secondaryClick
    )

    public init(
        doubleTap: MiragePencilGestureAction = .toggleDictation,
        squeeze: MiragePencilGestureAction = .secondaryClick
    ) {
        self.doubleTap = doubleTap
        self.squeeze = squeeze
    }

    public func action(for kind: MiragePencilGestureKind) -> MiragePencilGestureAction {
        switch kind {
        case .doubleTap:
            doubleTap
        case .squeeze:
            squeeze
        }
    }

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
