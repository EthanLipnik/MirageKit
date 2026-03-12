//
//  AppListRequestErrorClassificationTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKitHost
import Foundation
import Testing

@Suite("App List Request Error Classification")
struct AppListRequestErrorClassificationTests {
    @Test("Decoding errors are treated as malformed request failures")
    func decodingErrorsAreMalformedRequestFailures() {
        let error = DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "Broken request payload"
        ))

        #expect(MirageHostService.isMalformedAppListRequestError(error))
    }

    @Test("Coder corruption and missing-value cocoa errors are treated as malformed request failures")
    func cocoaDecodeFailuresAreMalformedRequestFailures() {
        let corrupt = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.coderReadCorrupt.rawValue)
        let missingValue = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.coderValueNotFound.rawValue)

        #expect(MirageHostService.isMalformedAppListRequestError(corrupt))
        #expect(MirageHostService.isMalformedAppListRequestError(missingValue))
    }

    @Test("Transport failures are not treated as malformed request failures")
    func transportFailuresAreNotMalformedRequestFailures() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 54)

        #expect(MirageHostService.isMalformedAppListRequestError(error) == false)
    }
}
