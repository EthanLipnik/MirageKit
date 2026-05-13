//
//  MirageEnumMapping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

/// Maps between Mirage enums that intentionally share the same string raw values across module boundaries.
///
/// Use this for protocol/public-model mirrors where every case is expected to stay in lockstep.
package func mirageMappedEnum<Source, Destination>(
    _ source: Source
) -> Destination where Source: RawRepresentable, Destination: RawRepresentable, Source.RawValue == String, Destination.RawValue == String {
    guard let destination = Destination(rawValue: source.rawValue) else {
        preconditionFailure("Unhandled Mirage enum value: \(source.rawValue)")
    }
    return destination
}
