//
//  PointerLockRetryPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

enum PointerLockRetryPolicy {
    static func shouldRetryEvaluation(
        pointerLockRequested: Bool,
        hasMouse: Bool,
        isLocked: Bool
    ) -> Bool {
        if pointerLockRequested {
            return !hasMouse || !isLocked
        }

        return isLocked
    }
}
