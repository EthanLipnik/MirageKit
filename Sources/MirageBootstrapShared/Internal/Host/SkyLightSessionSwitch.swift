//
//  SkyLightSessionSwitch.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Darwin
import Foundation

#if os(macOS)

/// Dynamically call `SLSSessionSwitchToUser` from the private SkyLight framework.
func callSLSSessionSwitchToUser(_ username: String) -> Int32? {
    guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
    defer { dlclose(skylight) }

    guard let sym = dlsym(skylight, "SLSSessionSwitchToUser") else { return nil }

    typealias SLSSessionSwitchToUserFunc = @convention(c) (UnsafePointer<CChar>) -> Int32
    let functionPointer = unsafeBitCast(sym, to: SLSSessionSwitchToUserFunc.self)

    return username.withCString { usernamePtr in
        functionPointer(usernamePtr)
    }
}

#endif
