//
//  MirageInstrumentation+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageDiagnostics


package enum MirageInstrumentation {
    package static func record(_ step: @autoclosure () -> MirageDiagnostics.MirageStepEvent) {
        LoomInstrumentation.record(LoomStepEvent(rawValue: step().name))
    }
}
