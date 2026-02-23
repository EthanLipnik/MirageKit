//
//  MirageBootstrapMetadataTests.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Bootstrap metadata serialization and Wake-on-LAN packet coverage.
//

import CloudKit
@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Bootstrap Metadata")
struct MirageBootstrapMetadataTests {
    @Test("Bootstrap metadata codable roundtrip")
    func bootstrapMetadataCodableRoundtrip() throws {
        let metadata = MirageBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            supportsAutomaticUnlock: true,
            endpoints: [
                MirageBootstrapEndpoint(host: "host-a.local", port: 22, source: .user),
                MirageBootstrapEndpoint(host: "10.0.0.21", port: 22, source: .auto),
            ],
            sshPort: 22,
            controlPort: 9851,
            wakeOnLAN: MirageWakeOnLANInfo(
                macAddress: "AA:BB:CC:DD:EE:FF",
                broadcastAddresses: ["10.0.0.255", "192.168.1.255"]
            )
        )

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(MirageBootstrapMetadata.self, from: encoded)

        #expect(decoded == metadata)
        #expect(decoded.version == MirageBootstrapMetadata.currentVersion)
        #expect(decoded.endpoints.count == 2)
        #expect(decoded.wakeOnLAN?.broadcastAddresses.count == 2)
    }

    @Test("CloudKit bootstrap metadata blob roundtrip")
    func cloudKitBootstrapMetadataBlobRoundtrip() throws {
        let metadata = MirageBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: false,
            supportsAutomaticUnlock: true,
            endpoints: [MirageBootstrapEndpoint(host: "203.0.113.9", port: 2222, source: .user)],
            sshPort: 2222,
            controlPort: 9851,
            wakeOnLAN: nil
        )

        let record = CKRecord(recordType: "Host", recordID: CKRecord.ID(recordName: UUID().uuidString))
        record[MirageCloudKitHostInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try JSONEncoder().encode(metadata)

        let blob = try #require(record[MirageCloudKitHostInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data)
        let decoded = try JSONDecoder().decode(MirageBootstrapMetadata.self, from: blob)
        #expect(decoded == metadata)
    }

    @Test("Wake-on-LAN magic packet format")
    func wakeOnLANMagicPacketFormat() throws {
        let packet = try MirageDefaultWakeOnLANClient.magicPacketData(for: "AA-BB-CC-DD-EE-FF")
        #expect(packet.count == 102)

        let bytes = [UInt8](packet)
        #expect(bytes.prefix(6).allSatisfy { $0 == 0xFF })

        let expectedMAC: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        #expect(Array(bytes[6 ..< 12]) == expectedMAC)
        #expect(Array(bytes[96 ..< 102]) == expectedMAC)
    }

    @Test("Wake-on-LAN invalid MAC rejection")
    func wakeOnLANInvalidMACRejection() {
        do {
            _ = try MirageDefaultWakeOnLANClient.magicPacketData(for: "invalid")
            Issue.record("Expected invalid MAC address rejection.")
        } catch let error as MirageWakeOnLANError {
            switch error {
            case .invalidMACAddress:
                break
            default:
                Issue.record("Expected invalidMACAddress, got \(error.localizedDescription).")
            }
        } catch {
            Issue.record("Expected MirageWakeOnLANError, got \(error.localizedDescription).")
        }
    }

    @Test("Bootstrap endpoint resolution order and dedupe")
    func bootstrapEndpointResolutionOrderAndDedupe() {
        let resolved = MirageBootstrapEndpointResolver.resolve([
            MirageBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .auto),
            MirageBootstrapEndpoint(host: "bootstrap.example.com", port: 2222, source: .user),
            MirageBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .lastSeen),
            MirageBootstrapEndpoint(host: "10.0.0.9", port: 22, source: .auto),
            MirageBootstrapEndpoint(host: "Bootstrap.Example.Com", port: 2222, source: .lastSeen),
            MirageBootstrapEndpoint(host: "198.51.100.22", port: 22, source: .lastSeen),
        ])

        #expect(resolved == [
            MirageBootstrapEndpoint(host: "bootstrap.example.com", port: 2222, source: .user),
            MirageBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .auto),
            MirageBootstrapEndpoint(host: "10.0.0.9", port: 22, source: .auto),
            MirageBootstrapEndpoint(host: "198.51.100.22", port: 22, source: .lastSeen),
        ])
    }

    @Test("SSH bootstrap rejects invalid endpoint")
    func sshBootstrapRejectsInvalidEndpoint() async {
        let client = MirageDefaultSSHBootstrapClient()
        do {
            _ = try await client.unlockVolumeOverSSH(
                endpoint: MirageBootstrapEndpoint(host: "   ", port: 22, source: .auto),
                username: "user",
                password: "password",
                expectedHostKeyFingerprint: nil,
                timeout: .seconds(1)
            )
            Issue.record("Expected invalid endpoint rejection.")
        } catch let error as MirageSSHBootstrapError {
            switch error {
            case .invalidEndpoint:
                break
            default:
                Issue.record("Expected invalidEndpoint, got \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Expected MirageSSHBootstrapError, got \(error.localizedDescription)")
        }
    }

    @Test("Bootstrap control protocol codable roundtrip")
    func bootstrapControlProtocolCodableRoundtrip() throws {
        let request = MirageBootstrapControlRequest(
            operation: .unlock,
            username: "ethan",
            password: "redacted-password"
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(MirageBootstrapControlRequest.self, from: requestData)
        #expect(decodedRequest.operation == .unlock)
        #expect(decodedRequest.username == "ethan")
        #expect(decodedRequest.requestID == request.requestID)

        let response = MirageBootstrapControlResponse(
            requestID: request.requestID,
            success: true,
            state: .active,
            message: "Host session is active.",
            canRetry: false,
            retriesRemaining: nil,
            retryAfterSeconds: nil
        )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(MirageBootstrapControlResponse.self, from: responseData)
        #expect(decodedResponse.requestID == request.requestID)
        #expect(decodedResponse.success)
        #expect(decodedResponse.state == .active)
    }
}
